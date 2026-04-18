#!/bin/bash
# UFreshClaw WeChat QR Bind (Core) - login with auto plugin install

UCLAW_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$UCLAW_DIR/app"
CORE_DIR="$APP_DIR/core"
DATA_DIR="$UCLAW_DIR/data"
STATE_DIR="$DATA_DIR/.openclaw"
CONFIG_PATH="$STATE_DIR/openclaw.json"
LOG_FILE="/tmp/uclaw-weixin-bind-mac.log"

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
OPENCLAW_MJS="$CORE_DIR/node_modules/openclaw/openclaw.mjs"
PLUGIN_JSON="$STATE_DIR/extensions/openclaw-weixin/openclaw.plugin.json"
TMP_BIN_DIR="/tmp/uclaw-open-bind-bin-mac"
WEIXIN_PLUGIN_PKG="@tencent-weixin/openclaw-weixin"
LOCAL_PLUGIN_TGZ="$UCLAW_DIR/plugins/openclaw-weixin.tgz"

{
  echo "[UCLAW] WeChat bind started"
  echo "[UCLAW] UCLAW_DIR=$UCLAW_DIR"
} >"$LOG_FILE"

mkdir -p "$STATE_DIR" "$DATA_DIR/memory" "$DATA_DIR/backups" "$DATA_DIR/logs" "$TMP_BIN_DIR" 2>/dev/null || true

export OPENCLAW_HOME="$DATA_DIR"
export OPENCLAW_STATE_DIR="$STATE_DIR"
export OPENCLAW_CONFIG_PATH="$CONFIG_PATH"

cat > "$TMP_BIN_DIR/openclaw" <<WRAPEOF
#!/bin/bash
exec "$NODE_BIN" "$OPENCLAW_MJS" "\$@"
WRAPEOF
chmod +x "$TMP_BIN_DIR/openclaw"
export PATH="$TMP_BIN_DIR:$CORE_DIR/node_modules/.bin:$NODE_DIR/bin:$PATH"

echo
echo "========================================"
echo "  UFreshClaw WeChat QR Bind (macOS)"
echo "  Login flow with auto plugin install"
echo "========================================"
echo "State: $OPENCLAW_STATE_DIR"
echo "Log  : $LOG_FILE"
echo

if [ ! -x "$NODE_BIN" ]; then
  echo "[ERROR] Node not found: $NODE_BIN"
  echo "[UCLAW] Node not found: $NODE_BIN" >>"$LOG_FILE"
  read -p "Press Enter to exit..."
  exit 1
fi
if [ ! -f "$OPENCLAW_MJS" ]; then
  echo "[ERROR] openclaw.mjs not found: $OPENCLAW_MJS"
  echo "[UCLAW] openclaw.mjs not found: $OPENCLAW_MJS" >>"$LOG_FILE"
  read -p "Press Enter to exit..."
  exit 1
fi
# Clean stale plugin install stage dirs to avoid duplicate-plugin errors.
if [ -d "$STATE_DIR/extensions" ]; then
  find "$STATE_DIR/extensions" -maxdepth 1 -type d -name '.openclaw-install-stage-*' -exec rm -rf {} + 2>/dev/null || true
fi

cd "$CORE_DIR" || {
  echo "[ERROR] core dir not found: $CORE_DIR"
  echo "[UCLAW] core dir not found: $CORE_DIR" >>"$LOG_FILE"
  read -p "Press Enter to exit..."
  exit 1
}

if [ ! -f "$PLUGIN_JSON" ]; then
  INSTALL_SPEC="$WEIXIN_PLUGIN_PKG"
  if [ -f "$LOCAL_PLUGIN_TGZ" ]; then
    INSTALL_SPEC="$LOCAL_PLUGIN_TGZ"
    echo "[INFO] WeChat plugin not found, installing from local package..."
    echo "[UCLAW] Plugin missing, installing from local package: $LOCAL_PLUGIN_TGZ" >>"$LOG_FILE"
  else
    echo "[INFO] WeChat plugin not found, local package missing, fallback to registry install..."
    echo "[UCLAW] Local package missing, fallback install: $WEIXIN_PLUGIN_PKG" >>"$LOG_FILE"
  fi
  "$NODE_BIN" "$OPENCLAW_MJS" plugins install "$INSTALL_SPEC" >>"$LOG_FILE" 2>&1
  if [ $? -ne 0 ] || [ ! -f "$PLUGIN_JSON" ]; then
    echo "[ERROR] Plugin install failed. Check log: $LOG_FILE"
    echo "[UCLAW] Plugin install failed" >>"$LOG_FILE"
    read -p "Press Enter to exit..."
    exit 1
  fi
  echo "[OK] Plugin installed."
  echo "[UCLAW] Plugin installed" >>"$LOG_FILE"
fi

echo "Starting WeChat QR login..."
echo "[UCLAW] Starting QR login" >>"$LOG_FILE"
# Important: no redirection here, so QR code appears in this terminal.
"$NODE_BIN" "$OPENCLAW_MJS" channels login --channel openclaw-weixin
RET=$?

if [ $RET -eq 0 ]; then
  "$NODE_BIN" "$OPENCLAW_MJS" gateway restart >>"$LOG_FILE" 2>&1 || true
  echo "[OK] WeChat QR bind completed."
  echo "[UCLAW] WeChat QR bind completed" >>"$LOG_FILE"
else
  echo "[ERROR] WeChat QR bind failed, code: $RET"
  echo "[UCLAW] WeChat QR bind failed, code: $RET" >>"$LOG_FILE"
fi

echo
read -p "Press Enter to exit..."
exit $RET
