#!/bin/bash
# Build distribution zip from current workspace.
# Usage:
#   bash release.sh [version] [output_dir]
# Optional env:
#   INCLUDE_DARWIN_X64_RUNTIME=0   Skip bundling/downloading macOS Intel runtime.
#   PERSIST_DARWIN_X64_RUNTIME=0   Do not cache downloaded Intel runtime back to repo.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:-v$(date +%Y%m%d_%H%M%S)}"
VERSION="${VERSION%.zip}"
OUT_DIR="${2:-$ROOT_DIR/dist}"
NODE_VERSION="${NODE_VERSION:-v22.22.1}"
NODE_MIRROR="${NODE_MIRROR:-https://npmmirror.com/mirrors/node}"
INCLUDE_DARWIN_X64_RUNTIME="${INCLUDE_DARWIN_X64_RUNTIME:-1}"
PERSIST_DARWIN_X64_RUNTIME="${PERSIST_DARWIN_X64_RUNTIME:-1}"
if [[ "$VERSION" == u-fresh-claw-* ]]; then
  PKG_NAME="$VERSION"
else
  PKG_NAME="u-fresh-claw-${VERSION}"
fi
STAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/uclaw-release.XXXXXX")"
STAGE_DIR="$STAGE_ROOT/$PKG_NAME"
ZIP_PATH="$OUT_DIR/$PKG_NAME.zip"
SHA_PATH="$ZIP_PATH.sha256"

cleanup() {
  rm -rf "$STAGE_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

if ! command -v rsync >/dev/null 2>&1; then
  echo "[ERROR] rsync not found"
  exit 1
fi

if ! command -v zip >/dev/null 2>&1; then
  echo "[ERROR] zip not found"
  exit 1
fi

mkdir -p "$OUT_DIR"
rm -rf "$ZIP_PATH" "$SHA_PATH"

ensure_stage_runtime() {
  local platform="$1"
  local target_dir="$2"
  local node_bin="$target_dir/bin/node"
  local tarball url tmp_tar repo_runtime

  if [ -x "$node_bin" ]; then
    return 0
  fi

  tarball="node-${NODE_VERSION}-${platform}.tar.gz"
  url="${NODE_MIRROR}/${NODE_VERSION}/${tarball}"
  tmp_tar="$(mktemp "${TMPDIR:-/tmp}/uclaw-node.${platform}.XXXXXX.tar.gz")"

  echo "[runtime] Missing ${platform} runtime, downloading..."
  echo "[runtime] $url"
  if ! curl -fL "$url" -o "$tmp_tar"; then
    rm -f "$tmp_tar"
    echo "[ERROR] Failed to download ${platform} runtime"
    exit 1
  fi

  mkdir -p "$target_dir"
  if ! tar -xzf "$tmp_tar" -C "$target_dir" --strip-components=1; then
    rm -f "$tmp_tar"
    echo "[ERROR] Failed to extract ${platform} runtime"
    exit 1
  fi
  rm -f "$tmp_tar"

  if [ "$platform" = "darwin-x64" ] && [ "$PERSIST_DARWIN_X64_RUNTIME" = "1" ]; then
    repo_runtime="$ROOT_DIR/oc/app/runtime/node-mac-x64"
    echo "[runtime] Caching ${platform} runtime to repo: $repo_runtime"
    mkdir -p "$(dirname "$repo_runtime")"
    rm -rf "$repo_runtime"
    mkdir -p "$repo_runtime"
    rsync -a "$target_dir"/ "$repo_runtime"/
  fi
}

repair_portable_node_runtime_shims() {
  local base_dir="$1"
  local runtime shim

  for runtime in "$base_dir"/oc/app/runtime/node-mac-* "$base_dir"/app/runtime/node-mac-*; do
    [ -d "$runtime/bin" ] || continue

    echo "[runtime] Normalizing portable Node shims: $runtime"
    mkdir -p "$runtime/bin"

    cat > "$runtime/bin/npm" <<'EOF'
#!/usr/bin/env node
require('../lib/node_modules/npm/bin/npm-cli.js')
EOF
    cat > "$runtime/bin/npx" <<'EOF'
#!/usr/bin/env node
require('../lib/node_modules/npm/bin/npx-cli.js')
EOF
    cat > "$runtime/bin/corepack" <<'EOF'
#!/usr/bin/env node
require('../lib/node_modules/corepack/dist/corepack.js')
EOF
    chmod +x "$runtime/bin/npm" "$runtime/bin/npx" "$runtime/bin/corepack"

    shim="$runtime/lib/node_modules/npm/bin/npm-cli.js"
    if [ -f "$shim" ]; then
      cat > "$shim" <<'EOF'
#!/usr/bin/env node
require('../lib/cli.js')(process)
EOF
      chmod +x "$shim"
    fi
  done
}

echo "[1/5] Copying files to staging: $STAGE_DIR"
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
  --exclude '/.gitignore' \
  --exclude '/.cache/' \
  --exclude '/tmp/' \
  --exclude '/temp/' \
  --exclude '/oc/data/' \
  --exclude '/oc/RESET_REPORT_*.md' \
  --exclude '/oc/data_reset_snapshot_*.txt' \
  --exclude '/extract-zip-to-usb.sh' \
  --exclude '/create-img.sh' \
  --exclude '/clone-usb.sh' \
  --exclude '/release.sh' \

if [ "$INCLUDE_DARWIN_X64_RUNTIME" = "1" ]; then
  echo "[2/5] Ensuring macOS x64 runtime"
  ensure_stage_runtime "darwin-x64" "$STAGE_DIR/oc/app/runtime/node-mac-x64"
else
  echo "[2/5] Skipping macOS x64 runtime (INCLUDE_DARWIN_X64_RUNTIME=0)"
fi

repair_portable_node_runtime_shims "$STAGE_DIR"

echo "[3/5] Re-creating empty runtime data directories"
mkdir -p "$STAGE_DIR/oc/data/.openclaw" \
         "$STAGE_DIR/oc/data/memory" \
         "$STAGE_DIR/oc/data/logs" \
         "$STAGE_DIR/oc/data/backups"

echo "[4/5] Compressing zip"
(
  cd "$STAGE_ROOT"
  zip -qr "$PKG_NAME.zip" "$PKG_NAME"
  mv "$PKG_NAME.zip" "$ZIP_PATH"
)

echo "[5/5] Generating checksum"
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
