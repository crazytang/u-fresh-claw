#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
用法:
  # 仅生成镜像（若已存在则跳过）
  ./upgrade/clone-image-to-usb-macos.sh <镜像文件路径(.img)>

  # 生成镜像后克隆到U盘（或镜像已存在则直接克隆）
  sudo ./upgrade/clone-image-to-usb-macos.sh <镜像文件路径(.img/.iso)> <目标磁盘>

参数示例:
  ./upgrade/clone-image-to-usb-macos.sh dist/u-fresh-claw-v0.0.3-upgrade-to-4.9.img
  sudo ./upgrade/clone-image-to-usb-macos.sh dist/u-fresh-claw-v0.0.3-upgrade-to-4.9.img disk4
  sudo ./upgrade/clone-image-to-usb-macos.sh dist/u-fresh-claw-v0.0.3-upgrade-to-4.9.iso /dev/disk4

说明:
  - 仅生成镜像模式下，不需要 sudo。
  - 克隆模式下，目标必须是整盘设备 (diskX)，脚本会拒绝分区 (diskXsY)。
  - 克隆会清空目标磁盘上的所有数据。
  - 默认镜像容量为 30000 MiB（适配常见 32GB U盘），可用 IMG_SIZE_MB 或 DEFAULT_IMG_SIZE_MB 覆盖。
USAGE

  echo ""
  echo "可用外置磁盘 (macOS):"
  diskutil list external physical || true
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

trim() {
  sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

if [ "$(uname -s)" != "Darwin" ]; then
  die "此脚本仅支持 macOS。"
fi

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  usage
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE_INPUT="$1"
TARGET_INPUT="${2:-}"

if [[ "$IMAGE_INPUT" != /* ]]; then
  IMAGE_PATH="$ROOT_DIR/$IMAGE_INPUT"
else
  IMAGE_PATH="$IMAGE_INPUT"
fi

# 仅生成镜像模式下，若通过 sudo 调用，自动切回原用户执行，避免权限/TCC问题。
if [ -z "$TARGET_INPUT" ] && [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
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
trap cleanup EXIT

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
    echo "  IMG_SIZE_MB=12288 ./upgrade/clone-image-to-usb-macos.sh \"$IMAGE_PATH\""
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

resolve_target_disk() {
  local target="$1"
  local info device_id part_of_whole disk_id

  info="$(diskutil info "$target" 2>/dev/null || true)"
  [ -n "$info" ] || die "无法识别目标: $target"

  device_id="$(printf '%s\n' "$info" | awk -F: '/Device Identifier:/ {print $2; exit}' | trim)"
  part_of_whole="$(printf '%s\n' "$info" | awk -F: '/Part of Whole:/ {print $2; exit}' | trim)"

  if [[ "$device_id" =~ ^disk[0-9]+$ ]]; then
    disk_id="$device_id"
  elif [[ "$device_id" =~ ^disk[0-9]+s[0-9]+$ ]] && [ -n "$part_of_whole" ]; then
    disk_id="$part_of_whole"
  elif [[ "$target" =~ ^/dev/r?disk[0-9]+$ ]]; then
    disk_id="$(basename "$target")"
    disk_id="${disk_id#r}"
  elif [[ "$target" =~ ^r?disk[0-9]+$ ]]; then
    disk_id="${target#r}"
  else
    die "无法解析目标磁盘: $target"
  fi

  printf '%s\n' "$disk_id"
}

clone_image_to_disk() {
  local disk_id="$1"
  local disk_info whole_flag internal_flag disk_size out_dev img_size_bytes

  disk_info="$(diskutil info "/dev/$disk_id" 2>/dev/null || true)"
  [ -n "$disk_info" ] || die "目标整盘不存在: /dev/$disk_id"

  whole_flag="$(printf '%s\n' "$disk_info" | awk -F: '/Whole:/ {print $2; exit}' | trim)"
  internal_flag="$(printf '%s\n' "$disk_info" | awk -F: '/Internal:/ {print $2; exit}' | trim)"
  disk_size="$(printf '%s\n' "$disk_info" | awk -F: '/Disk Size:/ {print $2; exit}' | trim)"

  [ "$whole_flag" = "Yes" ] || die "目标不是整盘设备，请使用 diskX (不是 diskXsY)。"
  [ "$internal_flag" = "No" ] || die "拒绝写入内置磁盘: /dev/$disk_id"

  if [ -b "/dev/r$disk_id" ]; then
    out_dev="/dev/r$disk_id"
  else
    out_dev="/dev/$disk_id"
  fi

  img_size_bytes="$(stat -f%z "$IMAGE_PATH")"

  echo "镜像文件 : $IMAGE_PATH"
  echo "镜像大小 : ${img_size_bytes} bytes"
  echo "目标磁盘 : /dev/$disk_id"
  echo "目标大小 : $disk_size"
  echo "写入设备 : $out_dev"
  echo ""
  echo "警告: 目标磁盘上的数据将被清空。"
  read -r -p "输入 YES 确认继续: " confirm
  if [ "$confirm" != "YES" ]; then
    echo "已取消。"
    exit 1
  fi

  echo "正在卸载目标磁盘..."
  diskutil unmountDisk force "/dev/$disk_id" >/dev/null

  echo "开始写入（请等待进度完成）..."
  dd if="$IMAGE_PATH" of="$out_dev" bs=8m status=progress conv=sync

  echo "正在同步缓存..."
  sync

  echo "尝试弹出磁盘..."
  diskutil eject "/dev/$disk_id" >/dev/null || true

  echo "克隆完成。"
}

ensure_image_exists

if [ -z "$TARGET_INPUT" ]; then
  echo "仅生成镜像模式完成。"
  exit 0
fi

if [ "$EUID" -ne 0 ]; then
  die "克隆到U盘需要 sudo。"
fi

disk_id="$(resolve_target_disk "$TARGET_INPUT")"
clone_image_to_disk "$disk_id"
