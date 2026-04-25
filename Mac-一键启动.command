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
export npm_config_registry="https://registry.npmmirror.com"
export npm_config_disturl="https://npmmirror.com/mirrors/node"
export npm_config_audit="false"
export npm_config_fund="false"
export npm_config_fetch_retries="5"
export npm_config_fetch_retry_mintimeout="2000"
export npm_config_fetch_retry_maxtimeout="20000"

# ---- 1.5 Self-heal npm/npx/corepack shims on FAT/ExFAT USB ----
repair_node_shim() {
    local shim="$1"
    local target="$2"
    local bad=0
    local shim_dir
    shim_dir="$(dirname "$shim")"
    [ -d "$shim_dir" ] || return 1

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

# 仅当 node 主程序存在时再尝试修复 shims，避免在 runtime 缺失时产生误导性日志。
if [ -f "$NODE_BIN" ]; then
    FIXED_SHIMS=0
    repair_node_shim "$NODE_DIR/bin/npm" "../lib/node_modules/npm/bin/npm-cli.js" && FIXED_SHIMS=1
    repair_node_shim "$NODE_DIR/bin/npx" "../lib/node_modules/npm/bin/npx-cli.js" && FIXED_SHIMS=1
    repair_node_shim "$NODE_DIR/bin/corepack" "../lib/node_modules/corepack/dist/corepack.js" && FIXED_SHIMS=1
    if [ "$FIXED_SHIMS" = "1" ]; then
        echo -e "  ${YELLOW}Detected damaged Node.js shims, auto-repaired${NC}"
    fi
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
    TMP_TARBALL="/tmp/$TARBALL"
    echo "  Download: $NODE_URL"
    if curl -fL --connect-timeout 15 --retry 2 "$NODE_URL" -o "$TMP_TARBALL"; then
        echo -e "  ${YELLOW}Download complete, extracting runtime...${NC}"
        if tar -xzf "$TMP_TARBALL" -C "$NODE_DIR" --strip-components=1; then
            rm -f "$TMP_TARBALL"
            chmod +x "$NODE_BIN" 2>/dev/null || true
            echo -e "  ${GREEN}Runtime extracted${NC}"
        else
            echo -e "  ${RED}Error: failed to extract Node.js runtime${NC}"
            rm -f "$TMP_TARBALL"
            rm -rf "$NODE_DIR"/bin "$NODE_DIR"/lib "$NODE_DIR"/include "$NODE_DIR"/share 2>/dev/null || true
        fi
    else
        echo -e "  ${RED}Error: Node.js runtime download failed${NC}"
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

# ---- 8. Validate config encoding/json and auto-repair if needed ----
normalize_and_validate_config() {
    [ -f "$CONFIG_FILE" ] || return 0

    local json5_path="$CORE_DIR/node_modules/openclaw/node_modules/json5"
    "$NODE_BIN" - "$CONFIG_FILE" "$json5_path" <<'NODEEOF'
const fs = require('fs');

const configPath = process.argv[2];
const json5Path = process.argv[3];
const raw = fs.readFileSync(configPath);

function decodeText(buf) {
  // UTF-16 LE BOM
  if (buf.length >= 2 && buf[0] === 0xff && buf[1] === 0xfe) {
    return buf.slice(2).toString('utf16le');
  }
  // UTF-16 BE BOM
  if (buf.length >= 2 && buf[0] === 0xfe && buf[1] === 0xff) {
    const swapped = Buffer.allocUnsafe(Math.max(0, buf.length - 2));
    for (let i = 2; i < buf.length; i += 2) {
      swapped[i - 2] = buf[i + 1] ?? 0;
      swapped[i - 1] = buf[i];
    }
    return swapped.toString('utf16le');
  }
  return buf.toString('utf8');
}

let text = decodeText(raw);
if (text.charCodeAt(0) === 0xfeff) text = text.slice(1); // strip UTF-8 BOM

let ok = false;
let lastErr = null;
try {
  JSON.parse(text);
  ok = true;
} catch (e) {
  lastErr = e;
}

if (!ok && json5Path && fs.existsSync(json5Path)) {
  try {
    const json5 = require(json5Path);
    json5.parse(text);
    ok = true;
  } catch (e) {
    lastErr = e;
  }
}

if (!ok) {
  console.error(lastErr ? String(lastErr.message || lastErr) : 'config parse failed');
  process.exit(2);
}

// Normalize to utf-8 text file after successful parse.
fs.writeFileSync(configPath, text, 'utf8');
NODEEOF
}

ensure_valid_config() {
    if normalize_and_validate_config; then
        return 0
    fi

    local broken="$CONFIG_FILE.broken.$(date +%Y%m%d_%H%M%S)"
    cp "$CONFIG_FILE" "$broken" 2>/dev/null || true
    echo -e "  ${YELLOW}Config invalid/corrupted, backup saved:${NC} $broken"
    cat > "$CONFIG_FILE" << 'CFGEOF'
{
  "gateway": {
    "mode": "local",
    "auth": { "token": "uclaw" }
  }
}
CFGEOF
    echo -e "  ${GREEN}Config reset to default. Please re-open Config Center to set model/API key.${NC}"
}

ensure_valid_config

# ---- 9. Cleanup old instance (same USB path only) ----
stop_old_instance() {
    local found=0
    local pid
    local gw_pattern="$CORE_DIR/node_modules/openclaw/openclaw.mjs gateway run"
    local cfg_pattern="$BASE_DIR/config-server/server.js"
    local gw_pids cfg_pids all_pids

    gw_pids=$(pgrep -f "$gw_pattern" 2>/dev/null || true)
    cfg_pids=$(pgrep -f "$cfg_pattern" 2>/dev/null || true)
    all_pids="$gw_pids $cfg_pids"

    for pid in $all_pids; do
        [ -z "$pid" ] && continue
        [ "$pid" = "$$" ] && continue
        found=1
        break
    done

    if [ "$found" = "0" ]; then
        return 0
    fi

    echo -e "  ${YELLOW}Detected running instance, stopping old process(es)...${NC}"
    for pid in $all_pids; do
        [ -z "$pid" ] && continue
        [ "$pid" = "$$" ] && continue
        kill "$pid" 2>/dev/null || true
    done

    sleep 1
    for pid in $all_pids; do
        [ -z "$pid" ] && continue
        [ "$pid" = "$$" ] && continue
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
    echo -e "  ${GREEN}Old instance stopped${NC}"
}

stop_old_instance

# ---- 10. Find available port ----
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

# ---- 11. Find available config center port ----
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

# ---- 12. Start Config Server in background ----
echo -e "  ${CYAN}Starting Config Center on port $CFG_PORT...${NC}"
CONFIG_SERVER="$BASE_DIR/config-server"
CONFIG_PORT="$CFG_PORT" GATEWAY_PORT="$PORT" "$NODE_BIN" "$CONFIG_SERVER/server.js" &
CONFIG_PID=$!
sleep 1

# ---- 13. Start gateway ----
echo -e "  ${CYAN}Starting OpenClaw on port $PORT...${NC}"
echo ""

cd "$CORE_DIR"
OPENCLAW_MJS="$CORE_DIR/node_modules/openclaw/openclaw.mjs"
"$NODE_BIN" "$OPENCLAW_MJS" gateway run --allow-unconfigured --force --port $PORT &
GW_PID=$!

# ---- 14. Wait for gateway, then open browser ----
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
