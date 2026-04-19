#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
DEFAULT_ZIP="$ROOT_DIR/dist/"
RUN_START_TS="$(date +%s)"
STAGE_DIR=""
CLEANUP_DONE=0

format_elapsed() {
  local total="$1"
  local h m s
  h=$((total / 3600))
  m=$(((total % 3600) / 60))
  s=$((total % 60))
  printf '%02d:%02d:%02d' "$h" "$m" "$s"
}

usage() {
  cat <<USAGE
用法:
  $(basename "$0") [--dry-run] <U盘挂载路径或卷名> [zip路径]

示例:
  $(basename "$0") MyUSB
  $(basename "$0") /Volumes/MyUSB
  $(basename "$0") /Volumes/MyUSB dist/u-fresh-claw-v0.0.2-test.zip
  $(basename "$0") --dry-run /Volumes/MyUSB

说明:
  - 不传 zip路径 时，默认使用: $DEFAULT_ZIP
  - 如果第一个参数不含 '/', 会按卷名拼接成 /Volumes/<卷名>
  - 若 zip 同目录存在 .sha256 文件，会自动校验
USAGE

  if [ -d "/Volumes" ]; then
    echo ""
    echo "当前 /Volumes 下可见卷:"
    ls -1 "/Volumes" | sed 's/^/  - /'
  fi
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_rsync_v3() {
  local ver major
  if ! command -v rsync >/dev/null 2>&1; then
    return 1
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

cleanup() {
  if [ "${CLEANUP_DONE:-0}" -eq 1 ]; then
    return 0
  fi
  CLEANUP_DONE=1
  if [ -n "${STAGE_DIR:-}" ] && [ -d "$STAGE_DIR" ]; then
    rm -rf "$STAGE_DIR" || true
    echo "已清理临时目录: $STAGE_DIR"
  fi
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

on_exit() {
  local rc=$?
  cleanup
  print_elapsed "$rc"
}

handle_interrupt() {
  echo ""
  echo "收到中断信号，正在清理临时目录..."
  cleanup
  exit 130
}

trap on_exit EXIT
trap handle_interrupt INT TERM HUP QUIT

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
  shift
fi

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  usage
  exit 1
fi

USB_INPUT="$1"
ZIP_PATH="${2:-$DEFAULT_ZIP}"

if [[ "$USB_INPUT" == */* ]]; then
  USB_DIR="$USB_INPUT"
else
  USB_DIR="/Volumes/$USB_INPUT"
fi

if [[ "$ZIP_PATH" != /* ]]; then
  ZIP_PATH="$ROOT_DIR/$ZIP_PATH"
fi

[ -d "$USB_DIR" ] || die "U盘路径不存在: $USB_DIR"
[ -w "$USB_DIR" ] || die "U盘路径不可写: $USB_DIR"
[ -f "$ZIP_PATH" ] || die "ZIP文件不存在: $ZIP_PATH"

ZIP_SHA_FILE="${ZIP_PATH}.sha256"
if [ -f "$ZIP_SHA_FILE" ]; then
  expected_sha="$(awk 'NR==1{print $1}' "$ZIP_SHA_FILE")"
  actual_sha="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"

  [ -n "$expected_sha" ] || die "SHA256文件格式异常: $ZIP_SHA_FILE"
  if [ "$expected_sha" != "$actual_sha" ]; then
    die "SHA256校验失败: expected=$expected_sha actual=$actual_sha"
  fi
  echo "SHA256校验通过: $actual_sha"
else
  echo "未找到 SHA256 文件，跳过校验: $ZIP_SHA_FILE"
fi

echo "ZIP      : $ZIP_PATH"
echo "目标U盘 : $USB_DIR"
echo "模式     : $([ "$DRY_RUN" -eq 1 ] && echo 'dry-run' || echo 'execute')"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry-run完成，未实际解压。"
  exit 0
fi

echo "正在统计 ZIP 条目..."
TOTAL_ENTRIES="$(unzip -Z -1 "$ZIP_PATH" | wc -l | tr -d ' ')"
if [ -z "$TOTAL_ENTRIES" ] || [ "$TOTAL_ENTRIES" -eq 0 ]; then
  die "ZIP 中未检测到可解压条目: $ZIP_PATH"
fi
echo "总条目数 : $TOTAL_ENTRIES"
echo "开始本地解压..."

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}uclaw-stage.XXXXXX")"

# 先解压到本地临时目录，并显示近似进度。
unzip -o "$ZIP_PATH" -d "$STAGE_DIR" 2>&1 | awk -v total="$TOTAL_ENTRIES" '
BEGIN {
  done = 0;
  shown = -1;
}
{
  if ($0 ~ /inflating:|extracting:|creating:|skipping:/) {
    done++;
    pct = int((done * 100) / total);
    if (pct > 100) pct = 100;
    if (pct != shown) {
      printf "\r解压进度: %3d%% (%d/%d)", pct, done, total;
      fflush();
      shown = pct;
    }
  }
}
END {
  printf "\r解压进度: 100%% (%d/%d)\n", total, total;
}
'

echo "本地解压目录: $STAGE_DIR"
SYNC_SOURCE="$STAGE_DIR"
TOP_LEVEL_COUNT="$(find "$STAGE_DIR" -mindepth 1 -maxdepth 1 ! -name "__MACOSX" ! -name ".DS_Store" | wc -l | tr -d ' ')"
if [ "$TOP_LEVEL_COUNT" -eq 1 ]; then
  TOP_LEVEL_ITEM="$(find "$STAGE_DIR" -mindepth 1 -maxdepth 1 ! -name "__MACOSX" ! -name ".DS_Store" | head -n 1)"
  if [ -d "$TOP_LEVEL_ITEM" ]; then
    SYNC_SOURCE="$TOP_LEVEL_ITEM"
    echo "检测到单一顶层目录: $(basename "$TOP_LEVEL_ITEM")"
    echo "将该目录内容同步到U盘根目录。"
  fi
fi
echo "同步源目录: $SYNC_SOURCE"
echo "开始同步到U盘..."

if command -v rsync >/dev/null 2>&1; then
  require_rsync_v3
  # 大量小文件场景下，先本地解压再用 rsync 同步通常更稳，后续重复同步也更快。
  # 使用 --no-inc-recursive 先完整建立文件列表，避免 progress2 百分比回退。
  COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 rsync -a --whole-file --omit-dir-times --no-inc-recursive --info=progress2 --no-xattrs --no-acls "$SYNC_SOURCE"/ "$USB_DIR"/
else
  echo "未检测到 rsync，回退到 cp -R（速度可能较慢）..."
  cp -R "$SYNC_SOURCE"/. "$USB_DIR"/
fi

echo "正在刷新写入缓存..."
sync 2>/dev/null || true

cleanup

echo "解压完成。"
