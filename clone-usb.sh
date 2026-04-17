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

usage() {
  cat <<'USAGE'
用法:
  sudo ./clone-usb.sh <镜像文件路径(.img/.iso/.dmg)> <目标磁盘>

参数示例:
  sudo ./clone-usb.sh dist/u-fresh-claw-v0.0.5-shrunk.img disk4
  sudo ./clone-usb.sh dist/u-fresh-claw-v0.0.5-shrunk.img /dev/disk4

说明:
  - 本脚本仅负责克隆已存在的镜像到U盘，不会生成镜像。
  - 目标必须是整盘设备 (diskX)，脚本会拒绝分区 (diskXsY)。
  - 目标必须出现在 `diskutil list external physical` 列表中。
  - 克隆会清空目标磁盘上的所有数据。
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

plist_get_bool() {
  local plist_file="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist_file" 2>/dev/null | tr '[:upper:]' '[:lower:]'
}

plist_get_str() {
  local plist_file="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist_file" 2>/dev/null | trim
}

on_exit() {
  local rc=$?
  print_elapsed "$rc"
}
trap on_exit EXIT

if [ "$(uname -s)" != "Darwin" ]; then
  die "此脚本仅支持 macOS。"
fi

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$#" -ne 2 ]; then
  usage
  exit 1
fi

if [ "$EUID" -ne 0 ]; then
  die "克隆到U盘需要 sudo。"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
IMAGE_INPUT="$1"
TARGET_INPUT="$2"

if [[ "$IMAGE_INPUT" != /* ]]; then
  IMAGE_PATH="$ROOT_DIR/$IMAGE_INPUT"
else
  IMAGE_PATH="$IMAGE_INPUT"
fi

[ -f "$IMAGE_PATH" ] || die "镜像文件不存在: $IMAGE_PATH"

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

is_external_physical_disk() {
  local disk_id="$1"
  local external_ids

  external_ids="$(diskutil list external physical 2>/dev/null | awk '/^\/dev\/disk[0-9]+/ {gsub("/dev/","",$1); print $1}')"
  printf '%s\n' "$external_ids" | grep -qx "$disk_id"
}

clone_image_to_disk() {
  local disk_id="$1"
  local disk_info disk_plist
  local whole_flag internal_flag disk_size disk_size_bytes out_dev img_size_bytes

  disk_info="$(diskutil info "/dev/$disk_id" 2>/dev/null || true)"
  [ -n "$disk_info" ] || die "目标整盘不存在: /dev/$disk_id"

  disk_plist="$(mktemp -t uclaw-diskinfo.XXXXXX)"
  if ! diskutil info -plist "/dev/$disk_id" >"$disk_plist" 2>/dev/null; then
    rm -f "$disk_plist"
    die "无法读取目标磁盘信息(plist): /dev/$disk_id"
  fi

  whole_flag="$(plist_get_bool "$disk_plist" WholeDisk)"
  internal_flag="$(plist_get_bool "$disk_plist" Internal)"
  disk_size_bytes="$(plist_get_str "$disk_plist" TotalSize)"
  disk_size="$(printf '%s\n' "$disk_info" | awk -F: '/Disk Size:/ {print $2; exit}' | trim)"
  rm -f "$disk_plist"

  [ "$whole_flag" = "true" ] || die "目标不是整盘设备，请使用 diskX (不是 diskXsY)。"
  [ "$internal_flag" = "false" ] || die "拒绝写入内置磁盘: /dev/$disk_id"
  is_external_physical_disk "$disk_id" || die "目标不在 external physical 列表中，拒绝写入: /dev/$disk_id"

  if [ -b "/dev/r$disk_id" ]; then
    out_dev="/dev/r$disk_id"
  else
    out_dev="/dev/$disk_id"
  fi

  img_size_bytes="$(stat -f%z "$IMAGE_PATH")"
  [ -n "$disk_size_bytes" ] || die "无法解析目标磁盘容量字节数: /dev/$disk_id"
  [[ "$disk_size_bytes" =~ ^[0-9]+$ ]] || die "目标磁盘容量字段异常: $disk_size_bytes"
  [ "$img_size_bytes" -le "$disk_size_bytes" ] || die "镜像大于目标磁盘容量，拒绝写入。"

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
  read -r -p "再次输入目标磁盘标识(例如 $disk_id)确认: " confirm_disk
  if [ "$confirm_disk" != "$disk_id" ]; then
    echo "二次确认不匹配，已取消。"
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

disk_id="$(resolve_target_disk "$TARGET_INPUT")"
clone_image_to_disk "$disk_id"
