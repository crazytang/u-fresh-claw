#!/bin/bash
# UFreshClaw OpenClaw onboard — same env as Mac-Weixin-Bind-Core.command

UCLAW_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$UCLAW_DIR/app"
CORE_DIR="$APP_DIR/core"
DATA_DIR="$UCLAW_DIR/data"
STATE_DIR="$DATA_DIR/.openclaw"
CONFIG_PATH="$STATE_DIR/openclaw.json"
LOG_FILE="/tmp/uclaw-openclaw-onboard-mac.log"

ARCH="$(uname -m)"
if [ "$ARCH" = "arm64" ]; then
  NODE_DIR="$APP_DIR/runtime/node-mac-arm64"
else
  NODE_DIR="$APP_DIR/runtime/node-mac-x64"
fi
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
TMP_BIN_DIR="/tmp/uclaw-open-onboard-bin-mac"

{
  echo "[UCLAW] openclaw onboard started"
  echo "[UCLAW] UCLAW_DIR=$UCLAW_DIR"
} >"$LOG_FILE"

mkdir -p "$STATE_DIR" "$DATA_DIR/memory" "$DATA_DIR/backups" "$DATA_DIR/logs" "$TMP_BIN_DIR" 2>/dev/null || true

export OPENCLAW_HOME="$DATA_DIR"
export OPENCLAW_STATE_DIR="$STATE_DIR"
export OPENCLAW_CONFIG_PATH="$CONFIG_PATH"
export npm_config_registry="https://registry.npmmirror.com"
export npm_config_disturl="https://npmmirror.com/mirrors/node"
export npm_config_audit="false"
export npm_config_fund="false"
export npm_config_fetch_retries="5"
export npm_config_fetch_retry_mintimeout="2000"
export npm_config_fetch_retry_maxtimeout="20000"
echo "[UCLAW] npm registry=$npm_config_registry" >>"$LOG_FILE"

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

echo
echo "========================================"
echo "  UFreshClaw OpenClaw onboard (macOS)"
echo "========================================"
echo "State: $OPENCLAW_STATE_DIR"
echo "Log  : $LOG_FILE"
echo

if [ ! -x "$NODE_BIN" ]; then
  echo "[ERROR] Node not found: $NODE_BIN"
  echo "[UCLAW] Node not found: $NODE_BIN" >>"$LOG_FILE"
  read -r -p "Press Enter to exit..."
  exit 1
fi
if [ ! -f "$OPENCLAW_MJS" ]; then
  echo "[ERROR] openclaw.mjs not found: $OPENCLAW_MJS"
  echo "[UCLAW] openclaw.mjs not found: $OPENCLAW_MJS" >>"$LOG_FILE"
  read -r -p "Press Enter to exit..."
  exit 1
fi

cd "$CORE_DIR" || {
  echo "[ERROR] core dir not found: $CORE_DIR"
  echo "[UCLAW] core dir not found: $CORE_DIR" >>"$LOG_FILE"
  read -r -p "Press Enter to exit..."
  exit 1
}

echo "[UCLAW] running onboard" >>"$LOG_FILE"
# Important: no redirection here, so onboarding prompts appear in this terminal.
"$NODE_BIN" "$OPENCLAW_MJS" onboard
RET=$?

if [ $RET -eq 0 ]; then
  echo "[OK] onboard finished."
  echo "[UCLAW] onboard finished (code=$RET)" >>"$LOG_FILE"
else
  echo "[ERROR] onboard failed, code: $RET"
  echo "[UCLAW] onboard failed (code=$RET)" >>"$LOG_FILE"
fi
