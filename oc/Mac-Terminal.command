#!/bin/bash
# U盘虾 quick terminal (portable USB, no write to USB required)

UCLAW_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$UCLAW_DIR/app"
CORE_DIR="$APP_DIR/core"
DATA_DIR="$UCLAW_DIR/data"
STATE_DIR="$DATA_DIR/.openclaw"
CONFIG_PATH="$STATE_DIR/openclaw.json"

# Migration shim: rename old core-mac to core
if [ -d "$APP_DIR/core-mac" ] && [ ! -d "$APP_DIR/core" ]; then
  mv "$APP_DIR/core-mac" "$APP_DIR/core"
fi

ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
  NODE_DIR="$APP_DIR/runtime/node-mac-arm64"
else
  NODE_DIR="$APP_DIR/runtime/node-mac-x64"
fi

# Fallback to any available mac runtime
if [ ! -x "$NODE_DIR/bin/node" ] && [ -x "$APP_DIR/runtime/node-mac-arm64/bin/node" ]; then
  NODE_DIR="$APP_DIR/runtime/node-mac-arm64"
fi
if [ ! -x "$NODE_DIR/bin/node" ] && [ -x "$APP_DIR/runtime/node-mac-x64/bin/node" ]; then
  NODE_DIR="$APP_DIR/runtime/node-mac-x64"
fi

NODE_BIN="$NODE_DIR/bin/node"
PY_LIB_SH="$UCLAW_DIR/lib/uclaw-python-runtime.sh"
if [ -f "$PY_LIB_SH" ]; then
  # shellcheck source=/dev/null
  . "$PY_LIB_SH"
  uclaw_python_runtime_export "$APP_DIR" "$ARCH"
  [ ! -x "$PYTHON_BIN" ] && uclaw_bootstrap_python_mac "$APP_DIR" "$ARCH" 2>/dev/null || true
  uclaw_python_runtime_export "$APP_DIR" "$ARCH"
fi
OPENCLAW_MJS="$CORE_DIR/node_modules/openclaw/openclaw.mjs"

# Best-effort create state dirs (don't fail if USB is temporarily read-only)
mkdir -p "$STATE_DIR" "$DATA_DIR/memory" "$DATA_DIR/backups" "$DATA_DIR/logs" 2>/dev/null || true

# Create launcher in /tmp so no write permission on USB is needed
TMP_BIN_DIR="/tmp/uclaw-open1-bin"
mkdir -p "$TMP_BIN_DIR"
cat > "$TMP_BIN_DIR/openclaw" <<WRAPEOF
#!/bin/bash
exec "$NODE_BIN" "$OPENCLAW_MJS" "\$@"
WRAPEOF
chmod +x "$TMP_BIN_DIR/openclaw"

export PATH="$TMP_BIN_DIR:$CORE_DIR/node_modules/.bin:$PATH"
if [ -f "$PY_LIB_SH" ]; then
  uclaw_export_path_portable_first "${PYTHON_DIR:-}" "$NODE_DIR"
else
  export PATH="$NODE_DIR/bin:$PATH"
fi
export OPENCLAW_HOME="$DATA_DIR"
export OPENCLAW_STATE_DIR="$STATE_DIR"
export OPENCLAW_CONFIG_PATH="$CONFIG_PATH"

clear
echo "========================================"
echo "  U盘虾 Quick Terminal (macOS)"
echo "========================================"
echo "UCLAW_DIR: $UCLAW_DIR"
echo "CORE_DIR : $CORE_DIR"
echo "STATE    : $OPENCLAW_STATE_DIR"

if [ -x "$NODE_BIN" ]; then
  NODE_VER=$($NODE_BIN --version 2>/dev/null || echo "N/A")
  echo "Node     : $NODE_VER"
else
  echo "Node     : NOT FOUND"
fi
if [ -f "$OPENCLAW_MJS" ]; then
  OC_VER=$($NODE_BIN "$OPENCLAW_MJS" --version 2>/dev/null || echo "N/A")
  echo "OpenClaw : $OC_VER"
else
  echo "OpenClaw : NOT FOUND"
fi

echo
echo "常用命令:"
echo "  openclaw --version"
echo "  openclaw doctor --repair"
echo "  openclaw gateway run --allow-unconfigured --force --port 18789"
echo

cd "$CORE_DIR" 2>/dev/null || cd "$UCLAW_DIR"
exec "${SHELL:-/bin/zsh}" -i
