#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_VERSION="${1:-latest}"

if [[ -x "$ROOT_DIR/oc/app/runtime/node-mac-arm64/bin/node" ]]; then
  NODE_BIN="$ROOT_DIR/oc/app/runtime/node-mac-arm64/bin/node"
elif [[ -x "$ROOT_DIR/oc/app/runtime/node-mac-x64/bin/node" ]]; then
  NODE_BIN="$ROOT_DIR/oc/app/runtime/node-mac-x64/bin/node"
elif command -v node >/dev/null 2>&1; then
  NODE_BIN="$(command -v node)"
else
  echo "ERROR: node not found" >&2
  exit 1
fi

"$NODE_BIN" "$SCRIPT_DIR/upgrade-openclaw.js" "$TARGET_VERSION"
