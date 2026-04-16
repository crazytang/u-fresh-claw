#!/bin/bash
# ============================================================
# U盘虾 - Portable AI Agent (macOS)
# Double-click to start / 双击启动
# ============================================================

UCLAW_DIR="$(cd "$(dirname "$0")" && pwd)"

# Support multiple portable layouts:
# 1) root/app
# 2) root/.uclaw-core/app
# 3) root/oc/app
if [ -d "$UCLAW_DIR/oc/app" ]; then
    BASE_DIR="$UCLAW_DIR/oc"
elif [ -d "$UCLAW_DIR/.uclaw-core/app" ]; then
    BASE_DIR="$UCLAW_DIR/.uclaw-core"
elif [ -d "$UCLAW_DIR/app" ]; then
    BASE_DIR="$UCLAW_DIR"
else
    echo "  Error: portable core not found."
    echo "  Expected one of:"
    echo "    $UCLAW_DIR/oc/app"
    echo "    $UCLAW_DIR/.uclaw-core/app"
    echo "    $UCLAW_DIR/app"
    read -p "  Press Enter to exit..."
    exit 1
fi

APP_DIR="$BASE_DIR/app"
CORE_DIR="$APP_DIR/core"
DATA_DIR="$BASE_DIR/data"
STATE_DIR="$DATA_DIR/.openclaw"
CONFIG_FILE="$STATE_DIR/openclaw.json"

# Migration shim: rename old core-mac to core for existing USB users
if [ -d "$APP_DIR/core-mac" ] && [ ! -d "$APP_DIR/core" ]; then
    mv "$APP_DIR/core-mac" "$APP_DIR/core"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

NODE_MIRROR="https://npmmirror.com/mirrors/node"
NODE_VERSION="v22.22.1"

echo ""
echo -e "${CYAN}"
echo "  ╔══════════════════════════════════════╗"
echo "  ║     🦞 U盘虾 v1.1                  ║"
echo "  ║     Portable AI Agent               ║"
echo "  ╚══════════════════════════════════════╝"
echo -e "${NC}"

# ---- 1. Detect CPU & set runtime ----
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    NODE_DIR="$APP_DIR/runtime/node-mac-arm64"
    echo -e "  ${GREEN}Apple Silicon (M series)${NC}"
elif [ "$ARCH" = "x86_64" ]; then
    NODE_DIR="$APP_DIR/runtime/node-mac-x64"
    echo -e "  ${GREEN}Intel Mac (x64)${NC}"
else
    echo -e "  ${RED}Unsupported architecture: $ARCH${NC}"
    echo ""
    read -p "  Press Enter to exit..."
    exit 1
fi

NODE_BIN="$NODE_DIR/bin/node"
export PATH="$NODE_DIR/bin:$PATH"

# ---- 1.5 Self-heal npm/npx/corepack shims on FAT/ExFAT USB ----
repair_node_shim() {
    local shim="$1"
    local target="$2"
    local bad=0

    if [ ! -f "$shim" ]; then
        bad=1
    else
        local first_line second_line
        first_line=$(sed -n '1p' "$shim" 2>/dev/null || true)
        second_line=$(sed -n '2p' "$shim" 2>/dev/null || true)
        [ "$first_line" != "#!/usr/bin/env node" ] && bad=1
        [ "$second_line" != "require('$target');" ] && bad=1
    fi

    if [ "$bad" = "1" ]; then
        [ -f "$shim" ] && cp "$shim" "$shim.brokenlink.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        cat > "$shim" <<SHIMEOF
#!/usr/bin/env node
require('$target');
SHIMEOF
        chmod +x "$shim" 2>/dev/null || true
        return 0
    fi

    return 1
}

FIXED_SHIMS=0
repair_node_shim "$NODE_DIR/bin/npm" "../lib/node_modules/npm/bin/npm-cli.js" && FIXED_SHIMS=1
repair_node_shim "$NODE_DIR/bin/npx" "../lib/node_modules/npm/bin/npx-cli.js" && FIXED_SHIMS=1
repair_node_shim "$NODE_DIR/bin/corepack" "../lib/node_modules/corepack/dist/corepack.js" && FIXED_SHIMS=1
if [ "$FIXED_SHIMS" = "1" ]; then
    echo -e "  ${YELLOW}Detected damaged Node.js shims, auto-repaired${NC}"
fi

# ---- 2. Remove macOS quarantine ----
if xattr -l "$NODE_BIN" 2>/dev/null | grep -q "com.apple.quarantine"; then
    echo -e "  ${YELLOW}Removing macOS security restriction...${NC}"
    xattr -rd com.apple.quarantine "$BASE_DIR" 2>/dev/null || true
    echo -e "  ${GREEN}Done${NC}"
fi

# ---- 3. Check runtime ----
if [ ! -f "$NODE_BIN" ]; then
    echo -e "  ${YELLOW}Node.js runtime not found, trying auto download...${NC}"
    if [ "$ARCH" = "arm64" ]; then
        NODE_PLATFORM="darwin-arm64"
    else
        NODE_PLATFORM="darwin-x64"
    fi
    TARBALL="node-${NODE_VERSION}-${NODE_PLATFORM}.tar.gz"
    NODE_URL="$NODE_MIRROR/$NODE_VERSION/$TARBALL"
    mkdir -p "$NODE_DIR"
    if curl -fL "$NODE_URL" -o "/tmp/$TARBALL"; then
        tar -xzf "/tmp/$TARBALL" -C "$NODE_DIR" --strip-components=1
        rm -f "/tmp/$TARBALL"
        chmod +x "$NODE_BIN" 2>/dev/null || true
    fi
fi

if [ ! -f "$NODE_BIN" ]; then
    echo -e "  ${RED}Error: Node.js runtime download failed${NC}"
    echo "  Please run: bash oc/setup.sh"
    read -p "  Press Enter to exit..."
    exit 1
fi

NODE_VER=$("$NODE_BIN" --version)
echo -e "  Node.js: ${GREEN}${NODE_VER}${NC}"
echo ""

# ---- 4. Init data directories ----
mkdir -p "$STATE_DIR" "$DATA_DIR/memory" "$DATA_DIR/backups" "$DATA_DIR/logs"

# ---- 5. Default config ----
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "  ${YELLOW}First run - creating default config...${NC}"
    cat > "$CONFIG_FILE" << 'CFGEOF'
{
  "gateway": {
    "mode": "local",
    "auth": { "token": "uclaw" }
  }
}
CFGEOF
    echo -e "  ${GREEN}Config created${NC}"
    echo ""
fi

# Sync config from legacy location
if [ -f "$DATA_DIR/config.json" ] && [ ! -f "$CONFIG_FILE" ]; then
    cp "$DATA_DIR/config.json" "$CONFIG_FILE"
fi

# ---- 6. Set environment (portable mode) ----
export OPENCLAW_HOME="$DATA_DIR"
export OPENCLAW_STATE_DIR="$STATE_DIR"
export OPENCLAW_CONFIG_PATH="$CONFIG_FILE"

# ---- 7. Check dependencies ----
if [ ! -d "$CORE_DIR/node_modules" ]; then
    echo -e "  ${YELLOW}First run - installing dependencies...${NC}"
    echo "  (Using China mirror)"
    cd "$CORE_DIR"
    "$NODE_BIN" "$NODE_DIR/lib/node_modules/npm/bin/npm-cli.js" install --registry=https://registry.npmmirror.com 2>&1
    echo -e "  ${GREEN}Dependencies installed${NC}"
    echo ""
fi

# ---- 8. Find available port ----
PORT=18789
while lsof -i :$PORT >/dev/null 2>&1; do
    echo -e "  ${YELLOW}Port $PORT in use, trying next...${NC}"
    PORT=$((PORT + 1))
    if [ $PORT -gt 18799 ]; then
        echo -e "  ${RED}No available port (18789-18799)${NC}"
        read -p "  Press Enter to exit..."
        exit 1
    fi
done

# ---- 9. Find available config center port ----
CFG_PORT=18788
while [ "$CFG_PORT" -eq "$PORT" ] || lsof -i :$CFG_PORT >/dev/null 2>&1; do
    echo -e "  ${YELLOW}Config port $CFG_PORT in use, trying next...${NC}"
    CFG_PORT=$((CFG_PORT + 1))
    if [ $CFG_PORT -gt 18798 ]; then
        echo -e "  ${RED}No available config port (18788-18798)${NC}"
        read -p "  Press Enter to exit..."
        exit 1
    fi
done

# ---- 10. Start Config Server in background ----
echo -e "  ${CYAN}Starting Config Center on port $CFG_PORT...${NC}"
CONFIG_SERVER="$BASE_DIR/config-server"
CONFIG_PORT="$CFG_PORT" GATEWAY_PORT="$PORT" "$NODE_BIN" "$CONFIG_SERVER/server.js" &
CONFIG_PID=$!
sleep 1

# ---- 11. Start gateway ----
echo -e "  ${CYAN}Starting OpenClaw on port $PORT...${NC}"
echo ""

cd "$CORE_DIR"
OPENCLAW_MJS="$CORE_DIR/node_modules/openclaw/openclaw.mjs"
"$NODE_BIN" "$OPENCLAW_MJS" gateway run --allow-unconfigured --force --port $PORT &
GW_PID=$!

# ---- 12. Wait for gateway, then open browser ----
GW_READY=0
for i in $(seq 1 120); do
    sleep 0.5
    if ! kill -0 "$GW_PID" 2>/dev/null; then
        echo -e "  ${RED}OpenClaw exited unexpectedly during startup${NC}"
        break
    fi
    if curl -fsS -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then
        GW_READY=1
        # Open Dashboard
        open "http://127.0.0.1:$PORT/#token=uclaw" 2>/dev/null || true
        # Open Config Center
        open "http://127.0.0.1:$CFG_PORT/?gatewayPort=$PORT" 2>/dev/null || true
        break
    fi
done

if [ "$GW_READY" != "1" ]; then
    echo -e "  ${YELLOW}Gateway not ready yet, opened Config Center only.${NC}"
    open "http://127.0.0.1:$CFG_PORT/?gatewayPort=$PORT" 2>/dev/null || true
fi

echo -e "  ${GREEN}════════════════════════════════${NC}"
echo -e "  ${GREEN}🦞 U盘虾 is running!${NC}"
echo -e "  ${GREEN}   Dashboard:     http://127.0.0.1:$PORT/#token=uclaw${NC}"
echo -e "  ${GREEN}   Config Center: http://127.0.0.1:$CFG_PORT/?gatewayPort=$PORT${NC}"
echo ""
echo -e "  ${YELLOW}Press Ctrl+C to stop${NC}"
echo -e "  ${GREEN}════════════════════════════════${NC}"
echo ""

# ---- Cleanup on exit ----
CLEANED=0
cleanup() {
    if [ "$CLEANED" = "1" ]; then
        return
    fi
    CLEANED=1

    # Try graceful stop through Config Center first (covers restarted gateway PID).
    curl -s -X POST "http://127.0.0.1:$CFG_PORT/api/gateway/stop" >/dev/null 2>&1 || true
    sleep 0.2
    kill "$GW_PID" 2>/dev/null || true
    kill "$CONFIG_PID" 2>/dev/null || true
    echo ""
    echo -e "  🦞 U盘虾 stopped."
    exit 0
}
trap cleanup INT TERM EXIT

# Keep script alive with Config Center lifecycle so gateway restart/stop in UI
# does not terminate this launcher script unexpectedly.
wait "$CONFIG_PID"
