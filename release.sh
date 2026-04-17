#!/bin/bash
# Build distribution zip from current workspace.
# Usage:
#   bash release.sh [version] [output_dir]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:-v$(date +%Y%m%d_%H%M%S)}"
OUT_DIR="${2:-$ROOT_DIR/dist}"
PKG_NAME="u-fresh-claw-${VERSION}"
STAGE_DIR="$OUT_DIR/$PKG_NAME"
ZIP_PATH="$OUT_DIR/$PKG_NAME.zip"
SHA_PATH="$ZIP_PATH.sha256"

if ! command -v rsync >/dev/null 2>&1; then
  echo "[ERROR] rsync not found"
  exit 1
fi

if ! command -v zip >/dev/null 2>&1; then
  echo "[ERROR] zip not found"
  exit 1
fi

mkdir -p "$OUT_DIR"
rm -rf "$STAGE_DIR" "$ZIP_PATH" "$SHA_PATH"

echo "[1/4] Copying files to staging: $STAGE_DIR"
rsync -a "$ROOT_DIR/" "$STAGE_DIR/" \
  --exclude '/.git/' \
  --exclude '/dist/' \
  --exclude '/.vscode/' \
  --exclude '/.idea/' \
  --exclude '.DS_Store' \
  --exclude '._*' \
  --exclude 'Thumbs.db' \
  --exclude 'Desktop.ini' \
  --exclude '/.env' \
  --exclude '/.env.*' \
  --exclude '/.cache/' \
  --exclude '/tmp/' \
  --exclude '/temp/' \
  --exclude '/oc/data/' \
  --exclude '/oc/RESET_REPORT_*.md' \
  --exclude '/oc/data_reset_snapshot_*.txt' \
  --exclude '/extract-zip-to-usb.sh' \
  --exclude '/clone-image-to-usb-macos.sh' \

echo "[2/4] Re-creating empty runtime data directories"
mkdir -p "$STAGE_DIR/oc/data/.openclaw" \
         "$STAGE_DIR/oc/data/memory" \
         "$STAGE_DIR/oc/data/logs" \
         "$STAGE_DIR/oc/data/backups"

echo "[3/4] Compressing zip"
(
  cd "$OUT_DIR"
  zip -qr "$PKG_NAME.zip" "$PKG_NAME"
)

rm -rf "$STAGE_DIR"

echo "[4/4] Generating checksum"
if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$ZIP_PATH" > "$SHA_PATH"
elif command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$ZIP_PATH" > "$SHA_PATH"
else
  echo "[WARN] No sha256 tool found, checksum file skipped"
fi

echo ""
echo "Build complete:"
echo "  ZIP: $ZIP_PATH"
if [ -f "$SHA_PATH" ]; then
  echo "  SHA256: $SHA_PATH"
fi
du -sh "$ZIP_PATH" | awk '{print "  Size: " $1}'
