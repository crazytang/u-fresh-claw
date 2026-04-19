#!/usr/bin/env bash
set -euo pipefail

RUN_START_TS="$(date +%s)"

format_elapsed() {
  local total="$1"
  local h m s
  h=$((total / 3600))
  m=$(((total % 3600) / 60))
  s=$((total % 60))
  printf '%02d:%02d:%02d' "$h" "$m" "$s"
}

print_elapsed() {
  local rc="$1"
  local end_ts elapsed status
  end_ts="$(date +%s)"
  elapsed=$((end_ts - RUN_START_TS))
  if [ "$rc" -eq 0 ]; then
    status="成功"
  else
    status="失败($rc)"
  fi
  echo "执行耗时 : $(format_elapsed "$elapsed")"
  echo "执行状态 : $status"
}

play_notice_sound() {
  local sound_file="/System/Library/Sounds/Glass.aiff"
  [ "${UCLAW_NO_SOUND:-0}" = "1" ] && return 0

  if command -v afplay >/dev/null 2>&1 && [ -f "$sound_file" ]; then
    afplay "$sound_file" >/dev/null 2>&1 &
    return 0
  fi

  # Fallback: terminal bell
  printf '\a' || true
}

usage() {
  cat <<'USAGE'
用法:
  ./create-img.sh <镜像文件路径(.img)>

参数示例:
  ./create-img.sh dist/u-fresh-claw-v0.0.3-upgrade-to-4.9.img

说明:
  - 仅生成镜像，不会写入U盘。
  - 如果镜像文件已存在，会直接跳过生成。
  - 若找不到同名目录，会尝试使用同名 ZIP 作为源。
  - 默认镜像容量为 30000 MiB（适配常见 32GB U盘），可用 IMG_SIZE_MB 或 DEFAULT_IMG_SIZE_MB 覆盖。
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_rsync_v3() {
  local ver major
  if ! command -v rsync >/dev/null 2>&1; then
    die "未检测到 rsync，请先安装后重试。"
  fi

  ver="$(rsync --version 2>/dev/null | awk 'NR==1{print $3}')"
  major="${ver%%.*}"
  if ! printf '%s' "$major" | grep -Eq '^[0-9]+$'; then
    die "无法识别 rsync 版本: ${ver:-unknown}"
  fi

  if [ "$major" -lt 3 ]; then
    echo "检测到 rsync 版本过低: ${ver}（当前脚本需要 3.x）。"
    echo "原因: 需要 --no-inc-recursive / --info=progress2 参数。"
    echo "请先安装新版 rsync（例如: brew install rsync），再重试。"
    exit 1
  fi
}

trim() {
  sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

if [ "$(uname -s)" != "Darwin" ]; then
  die "此脚本仅支持 macOS。"
fi

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$#" -ne 1 ]; then
  usage
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
IMAGE_INPUT="$1"

if [[ "$IMAGE_INPUT" != /* ]]; then
  IMAGE_PATH="$ROOT_DIR/$IMAGE_INPUT"
else
  IMAGE_PATH="$IMAGE_INPUT"
fi

# 仅生成镜像模式下，若通过 sudo 调用，自动切回原用户执行，避免权限/TCC问题。
if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  echo "检测到仅生成镜像模式，自动切换到用户 ${SUDO_USER} 执行。"
  exec sudo -u "$SUDO_USER" -- "$0" "$IMAGE_INPUT"
fi

GEN_TMP_SOURCE=""
GEN_TMP_MOUNT=""
GEN_ATTACHED_DEV=""

cleanup() {
  if [ -n "$GEN_ATTACHED_DEV" ]; then
    hdiutil detach "$GEN_ATTACHED_DEV" >/dev/null 2>&1 || true
    GEN_ATTACHED_DEV=""
  fi
  if [ -n "$GEN_TMP_MOUNT" ] && [ -d "$GEN_TMP_MOUNT" ]; then
    rm -rf "$GEN_TMP_MOUNT" || true
    GEN_TMP_MOUNT=""
  fi
  if [ -n "$GEN_TMP_SOURCE" ] && [ -d "$GEN_TMP_SOURCE" ]; then
    rm -rf "$GEN_TMP_SOURCE" || true
    GEN_TMP_SOURCE=""
  fi
}

on_exit() {
  local rc=$?
  cleanup
  print_elapsed "$rc"
  play_notice_sound
}
trap on_exit EXIT

pick_sync_source() {
  local base="$1"
  local count
  count="$(find "$base" -mindepth 1 -maxdepth 1 ! -name "__MACOSX" ! -name ".DS_Store" | wc -l | tr -d ' ')"
  if [ "$count" -eq 1 ]; then
    local item
    item="$(find "$base" -mindepth 1 -maxdepth 1 ! -name "__MACOSX" ! -name ".DS_Store" | head -n 1)"
    if [ -d "$item" ]; then
      printf '%s\n' "$item"
      return
    fi
  fi
  printf '%s\n' "$base"
}

ensure_image_exists() {
  if [ -f "$IMAGE_PATH" ]; then
    echo "镜像已存在，跳过生成: $IMAGE_PATH"
    return
  fi

  [[ "$IMAGE_PATH" == *.img ]] || die "镜像不存在且扩展名不是 .img，无法自动生成: $IMAGE_PATH"

  local base_no_ext source_dir source_zip sync_source
  base_no_ext="${IMAGE_PATH%.img}"
  source_dir="$base_no_ext"
  source_zip="${base_no_ext}.zip"

  if [ -d "$source_dir" ]; then
    sync_source="$source_dir"
  elif [ -f "$source_zip" ]; then
    echo "未找到同名目录，改用 ZIP 作为源: $source_zip"
    GEN_TMP_SOURCE="$(mktemp -d "${TMPDIR:-/tmp}/uclaw-img-src.XXXXXX")"
    unzip -oq "$source_zip" -d "$GEN_TMP_SOURCE"
    sync_source="$(pick_sync_source "$GEN_TMP_SOURCE")"
  else
    die "无法自动生成镜像：未找到同名目录或同名ZIP。\n期望其一存在：\n  $source_dir\n  $source_zip"
  fi

  [ -d "$sync_source" ] || die "源目录不可用: $sync_source"
  require_rsync_v3

  local source_bytes file_count dir_count slack_bytes dir_bytes overhead_bytes total_bytes estimated_mb size_mb default_img_size_mb vol_name raw_vol_name
  source_bytes=$(( $(du -sk "$sync_source" | awk '{print $1}') * 1024 ))
  file_count="$(find "$sync_source" -type f | wc -l | tr -d ' ')"
  dir_count="$(find "$sync_source" -type d | wc -l | tr -d ' ')"
  # ExFAT 在大量小文件场景会出现明显空间放大（cluster slack）。
  # 这里按每文件 32KiB + 每目录 4KiB 做保守估算，并叠加固定开销与 20% 余量。
  slack_bytes=$((file_count * 32 * 1024))
  dir_bytes=$((dir_count * 4 * 1024))
  overhead_bytes=$((1024 * 1024 * 1024))
  total_bytes=$((source_bytes + slack_bytes + dir_bytes + overhead_bytes))
  total_bytes=$((total_bytes + total_bytes / 5))
  if [ "$total_bytes" -lt $((4 * 1024 * 1024 * 1024)) ]; then
    total_bytes=$((4 * 1024 * 1024 * 1024))
  fi
  estimated_mb=$(((total_bytes + 1024*1024 - 1) / (1024*1024)))
  # 32GB U盘（标称）可用容量通常小于 32768 MiB，这里默认 30000 MiB 以兼容常见 32GB 盘。
  default_img_size_mb="${DEFAULT_IMG_SIZE_MB:-30000}"
  if [ -n "${IMG_SIZE_MB:-}" ]; then
    size_mb="${IMG_SIZE_MB}"
  elif [ "$estimated_mb" -gt "$default_img_size_mb" ]; then
    size_mb="$estimated_mb"
    echo "自动估算容量 ${estimated_mb} MiB 超过默认 ${default_img_size_mb} MiB，已自动上调。"
  else
    size_mb="$default_img_size_mb"
  fi
  raw_vol_name="$(basename "$base_no_ext")"
  # hdiutil + ExFAT 对卷标长度限制较严格（实测超过 11 字符会失败并报 Operation not permitted）。
  # 这里做字符清洗 + 截断，避免生成失败。
  vol_name="$(printf '%s' "$raw_vol_name" | tr -cd 'A-Za-z0-9 _-.' | cut -c1-11)"
  [ -n "$vol_name" ] || vol_name="UFreshClaw"

  mkdir -p "$(dirname "$IMAGE_PATH")"

  echo "开始生成镜像..."
  echo "源目录   : $sync_source"
  echo "目标镜像 : $IMAGE_PATH"
  echo "镜像大小 : ${size_mb} MiB"
  echo "估算大小 : ${estimated_mb} MiB, 源大小=${source_bytes} bytes, files=${file_count}, dirs=${dir_count}"
  echo "卷标名称 : ${vol_name} (from ${raw_vol_name})"

  local image_create_path image_attach_path
  image_create_path="$IMAGE_PATH"
  image_attach_path="$IMAGE_PATH"
  if [[ "$IMAGE_PATH" != *.dmg ]]; then
    image_create_path="${IMAGE_PATH}.dmg"
    image_attach_path="$image_create_path"
  fi

  rm -f "$image_create_path"
  hdiutil create -size "${size_mb}m" -fs ExFAT -volname "$vol_name" -ov "$image_create_path" >/dev/null

  GEN_TMP_MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/uclaw-img-mnt.XXXXXX")"
  hdiutil attach "$image_attach_path" -nobrowse -mountpoint "$GEN_TMP_MOUNT" >/dev/null
  GEN_ATTACHED_DEV="$(diskutil info "$GEN_TMP_MOUNT" | awk -F: '/Device Node:/ {print $2; exit}' | trim)"
  [ -n "$GEN_ATTACHED_DEV" ] || die "无法获取镜像挂载设备。"

  echo "正在写入镜像内容..."
  df -h "$GEN_TMP_MOUNT" | sed 's/^/  /'
  if ! COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 rsync -a --whole-file --omit-dir-times --no-inc-recursive --info=progress2 --no-xattrs --no-acls "$sync_source"/ "$GEN_TMP_MOUNT"/; then
    echo ""
    echo "镜像写入失败，当前镜像挂载可用空间如下:"
    df -h "$GEN_TMP_MOUNT" | sed 's/^/  /' || true
    echo "可尝试增大镜像容量（单位 MiB）后重试，例如："
    echo "  IMG_SIZE_MB=12288 ./create-img.sh \"$IMAGE_PATH\""
    exit 1
  fi
  sync

  hdiutil detach "$GEN_ATTACHED_DEV" >/dev/null
  GEN_ATTACHED_DEV=""
  rm -rf "$GEN_TMP_MOUNT"
  GEN_TMP_MOUNT=""

  if [ "$image_create_path" != "$IMAGE_PATH" ]; then
    mv -f "$image_create_path" "$IMAGE_PATH"
  fi

  echo "镜像生成完成: $IMAGE_PATH"
}

ensure_image_exists
echo "仅生成镜像模式完成。"
