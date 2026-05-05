#!/bin/bash
# ============================================================
# U盘虾 Portable — 开发环境搭建脚本
# 用法: bash setup.sh
# 作用: 下载 Node.js 运行时 + 安装 OpenClaw 到 app/ 目录
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$SCRIPT_DIR/app"
CORE_DIR="$APP_DIR/core"
RUNTIME_DIR="$APP_DIR/runtime"
MIRROR="https://registry.npmmirror.com"
NODE_MIRROR="https://npmmirror.com/mirrors/node"
NODE_VERSION="v24.15.0"
# CPython 3.12 — astral-sh/python-build-standalone，仅 npmmirror 二进制镜像（版本由 PY_STANDALONE_TAG 固定）
PY_STANDALONE_TAG="20260303"
PY_CPYTHON_FULL="3.12.13"
PY_DOWNLOAD_BASE="https://registry.npmmirror.com/-/binary/python-build-standalone/${PY_STANDALONE_TAG}"
ALL_PLATFORMS=false
[ "$1" = "--all-platforms" ] && ALL_PLATFORMS=true

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo ""
echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  🦞 U盘虾 Portable Setup           ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
echo ""

# ---- Detect OS & Arch ----
OS=$(uname -s)
ARCH=$(uname -m)

if [ "$OS" = "Darwin" ]; then
    # uname -m: arm64 = Apple Silicon; x86_64 = Intel. Maps to official Node tarball
    # names (darwin-arm64 / darwin-x64) and local dirs node-mac-* under app/runtime/.
    if [ "$ARCH" = "arm64" ]; then
        PLATFORM="darwin-arm64"
        NODE_DIR_NAME="node-mac-arm64"
    else
        PLATFORM="darwin-x64"
        NODE_DIR_NAME="node-mac-x64"
    fi
else
    echo -e "${RED}请在 Mac 上运行此脚本。Windows 请用 setup.bat${NC}"
    exit 1
fi

echo -e "  系统: ${GREEN}$OS $ARCH${NC}"
echo ""

# ---- 1. Download Node.js (Current Platform) ----
NODE_TARGET="$RUNTIME_DIR/$NODE_DIR_NAME"

if [ -f "$NODE_TARGET/bin/node" ]; then
    echo -e "  ${GREEN}✓${NC} Node.js ($PLATFORM) 已存在，跳过下载"
else
    echo -e "  ${CYAN}↓${NC} 下载 Node.js $NODE_VERSION ($PLATFORM)..."
    mkdir -p "$NODE_TARGET"

    NODE_URL="$NODE_MIRROR/$NODE_VERSION/node-$NODE_VERSION-$PLATFORM.tar.gz"
    echo "    $NODE_URL"

    curl -fSL "$NODE_URL" | tar xz -C "$NODE_TARGET" --strip-components=1

    if [ -f "$NODE_TARGET/bin/node" ]; then
        echo -e "  ${GREEN}✓${NC} Node.js ($PLATFORM) 下载完成"
    else
        echo -e "  ${RED}✗ Node.js 下载失败${NC}"
        exit 1
    fi
fi

# ---- 1a. Download Python 3.12 (current Mac platform) ----
PY_DIR_NAME="python-mac-${NODE_DIR_NAME#node-mac-}"
PY_TARGET="$RUNTIME_DIR/$PY_DIR_NAME"
case "$PLATFORM" in
    darwin-arm64) PY_ASSET="cpython-${PY_CPYTHON_FULL}+${PY_STANDALONE_TAG}-aarch64-apple-darwin-install_only.tar.gz" ;;
    darwin-x64) PY_ASSET="cpython-${PY_CPYTHON_FULL}+${PY_STANDALONE_TAG}-x86_64-apple-darwin-install_only.tar.gz" ;;
esac

write_uclaw_pip_conf_in() {
    local d="$1"
    [ -x "$d/bin/python3" ] || return 0
    cat >"$d/uclaw-pip.conf" <<'UCLAWPIPEOF'
[global]
index-url = https://mirrors.aliyun.com/pypi/simple/
trusted-host = mirrors.aliyun.com
timeout = 120
UCLAWPIPEOF
}

if [ -x "$PY_TARGET/bin/python3" ]; then
    echo -e "  ${GREEN}✓${NC} Python 3.12 ($PLATFORM) 已存在，跳过下载"
else
    echo -e "  ${CYAN}↓${NC} 下载 Python ${PY_CPYTHON_FULL} ($PLATFORM)..."
    mkdir -p "$PY_TARGET"
    PY_URL="$PY_DOWNLOAD_BASE/$PY_ASSET"
    echo "    $PY_URL"
    TMP_PY="/tmp/$PY_ASSET"
    if curl -fSL "$PY_URL" -o "$TMP_PY"; then
        tar xzf "$TMP_PY" -C "$PY_TARGET" --strip-components=1
        rm -f "$TMP_PY"
        chmod +x "$PY_TARGET/bin/python3" 2>/dev/null || true
    fi
    if [ -x "$PY_TARGET/bin/python3" ]; then
        echo -e "  ${GREEN}✓${NC} Python ($PLATFORM) 下载完成"
    else
        echo -e "  ${YELLOW}⚠${NC} Python 下载失败（不影响 Node/OpenClaw）"
        rm -f "$TMP_PY"
    fi
fi
write_uclaw_pip_conf_in "$PY_TARGET"

# ---- 1b. Extra runtimes (--all-platforms): Win Node (x64+arm64), other-mac Node, cross Python ----
if [ "$ALL_PLATFORMS" = "true" ]; then
    WIN_NODE_TARGET="$RUNTIME_DIR/node-win-x64"
    if [ -f "$WIN_NODE_TARGET/node.exe" ]; then
        echo -e "  ${GREEN}✓${NC} Node.js (win-x64) 已存在，跳过下载"
    else
        echo -e "  ${CYAN}↓${NC} 下载 Node.js $NODE_VERSION (win-x64) - Windows支持..."
        mkdir -p "$WIN_NODE_TARGET"

        WIN_NODE_URL="$NODE_MIRROR/$NODE_VERSION/node-$NODE_VERSION-win-x64.zip"
        echo "    $WIN_NODE_URL"

        TMP_ZIP="/tmp/node-win-x64-$$.zip"
        curl -fSL "$WIN_NODE_URL" -o "$TMP_ZIP"

        if command -v unzip >/dev/null 2>&1; then
            unzip -q "$TMP_ZIP" -d "/tmp/node-win-extract-$$"
            cp -r "/tmp/node-win-extract-$$"/node-$NODE_VERSION-win-x64/* "$WIN_NODE_TARGET/"
            rm -rf "/tmp/node-win-extract-$$"
        else
            echo -e "    ${RED}✗ unzip not found, skipping Windows runtime${NC}"
        fi
        rm -f "$TMP_ZIP"

        if [ -f "$WIN_NODE_TARGET/node.exe" ]; then
            echo -e "  ${GREEN}✓${NC} Node.js (win-x64) 下载完成"
        else
            echo -e "  ${CYAN}⚠${NC}  Windows runtime下载失败 (不影响当前平台使用)"
        fi
    fi

    WIN_ARM_NODE_TARGET="$RUNTIME_DIR/node-win-arm64"
    if [ -f "$WIN_ARM_NODE_TARGET/node.exe" ]; then
        echo -e "  ${GREEN}✓${NC} Node.js (win-arm64) 已存在，跳过下载"
    else
        echo -e "  ${CYAN}↓${NC} 下载 Node.js $NODE_VERSION (win-arm64)..."
        mkdir -p "$WIN_ARM_NODE_TARGET"

        WIN_ARM_NODE_URL="$NODE_MIRROR/$NODE_VERSION/node-$NODE_VERSION-win-arm64.zip"
        echo "    $WIN_ARM_NODE_URL"

        TMP_ZIP_ARM="/tmp/node-win-arm64-$$.zip"
        curl -fSL "$WIN_ARM_NODE_URL" -o "$TMP_ZIP_ARM"

        if command -v unzip >/dev/null 2>&1; then
            unzip -q "$TMP_ZIP_ARM" -d "/tmp/node-win-arm64-extract-$$"
            cp -r "/tmp/node-win-arm64-extract-$$"/node-$NODE_VERSION-win-arm64/* "$WIN_ARM_NODE_TARGET/"
            rm -rf "/tmp/node-win-arm64-extract-$$"
        else
            echo -e "    ${RED}✗ unzip not found, skipping Windows ARM64 runtime${NC}"
        fi
        rm -f "$TMP_ZIP_ARM"

        if [ -f "$WIN_ARM_NODE_TARGET/node.exe" ]; then
            echo -e "  ${GREEN}✓${NC} Node.js (win-arm64) 下载完成"
        else
            echo -e "  ${CYAN}⚠${NC}  Windows ARM64 Node 下载失败 (不影响当前平台使用)"
        fi
    fi

    # Node.js: other macOS arch (darwin-arm64 <-> darwin-x64 for portable U 盘 / 两台 Mac)
    if [ "$PLATFORM" = "darwin-arm64" ]; then
        OTHER_MAC_NODE_PF="darwin-x64"
        OTHER_MAC_NODE_DIR="$RUNTIME_DIR/node-mac-x64"
    else
        OTHER_MAC_NODE_PF="darwin-arm64"
        OTHER_MAC_NODE_DIR="$RUNTIME_DIR/node-mac-arm64"
    fi
    if [ -f "$OTHER_MAC_NODE_DIR/bin/node" ]; then
        echo -e "  ${GREEN}✓${NC} Node.js ($OTHER_MAC_NODE_PF) 已存在，跳过下载"
    else
        echo -e "  ${CYAN}↓${NC} 下载 Node.js $NODE_VERSION ($OTHER_MAC_NODE_PF) - 另一架构 macOS..."
        mkdir -p "$OTHER_MAC_NODE_DIR"
        OTHER_NODE_URL="$NODE_MIRROR/$NODE_VERSION/node-$NODE_VERSION-$OTHER_MAC_NODE_PF.tar.gz"
        echo "    $OTHER_NODE_URL"
        if curl -fSL "$OTHER_NODE_URL" | tar xz -C "$OTHER_MAC_NODE_DIR" --strip-components=1; then
            if [ -f "$OTHER_MAC_NODE_DIR/bin/node" ]; then
                echo -e "  ${GREEN}✓${NC} Node.js ($OTHER_MAC_NODE_PF) 下载完成"
            else
                echo -e "  ${CYAN}⚠${NC}  Node (other mac arch) 解压异常 (不影响当前平台)"
            fi
        else
            echo -e "  ${CYAN}⚠${NC}  Node (other mac arch) 下载失败 (不影响当前平台)"
        fi
    fi

    # Python: other macOS arch + Windows (install_only)
    if [ "$PLATFORM" = "darwin-arm64" ]; then
        OTHER_MAC_PY="$RUNTIME_DIR/python-mac-x64"
        OTHER_MAC_ASSET="cpython-${PY_CPYTHON_FULL}+${PY_STANDALONE_TAG}-x86_64-apple-darwin-install_only.tar.gz"
    else
        OTHER_MAC_PY="$RUNTIME_DIR/python-mac-arm64"
        OTHER_MAC_ASSET="cpython-${PY_CPYTHON_FULL}+${PY_STANDALONE_TAG}-aarch64-apple-darwin-install_only.tar.gz"
    fi
    if [ -x "$OTHER_MAC_PY/bin/python3" ]; then
        echo -e "  ${GREEN}✓${NC} Python (other mac arch) 已存在，跳过"
    else
        echo -e "  ${CYAN}↓${NC} 下载 Python ${PY_CPYTHON_FULL} (另一架构 macOS)..."
        mkdir -p "$OTHER_MAC_PY"
        OURL="$PY_DOWNLOAD_BASE/$OTHER_MAC_ASSET"
        OTMP="/tmp/$OTHER_MAC_ASSET"
        if curl -fSL "$OURL" -o "$OTMP"; then
            tar xzf "$OTMP" -C "$OTHER_MAC_PY" --strip-components=1
            rm -f "$OTMP"
            chmod +x "$OTHER_MAC_PY/bin/python3" 2>/dev/null || true
            echo -e "  ${GREEN}✓${NC} Python (other mac arch) 完成"
        else
            echo -e "  ${YELLOW}⚠${NC} Python (other mac arch) 下载失败"
            rm -f "$OTMP"
        fi
    fi
    write_uclaw_pip_conf_in "$OTHER_MAC_PY"

    WIN_PY_TARGET="$RUNTIME_DIR/python-win-amd64"
    WIN_PY_ASSET="cpython-${PY_CPYTHON_FULL}+${PY_STANDALONE_TAG}-x86_64-pc-windows-msvc-install_only.tar.gz"
    if [ -f "$WIN_PY_TARGET/python.exe" ]; then
        echo -e "  ${GREEN}✓${NC} Python (win-amd64) 已存在，跳过"
    else
        echo -e "  ${CYAN}↓${NC} 下载 Python ${PY_CPYTHON_FULL} (win-amd64)..."
        mkdir -p "$WIN_PY_TARGET"
        WURL="$PY_DOWNLOAD_BASE/$WIN_PY_ASSET"
        WTAR="/tmp/py-win-amd64-$$.tar.gz"
        if curl -fSL "$WURL" -o "$WTAR"; then
            if tar -xzf "$WTAR" -C "$WIN_PY_TARGET" --strip-components=1; then
                rm -f "$WTAR"
            else
                echo -e "    ${RED}✗ 解压 Windows Python 失败${NC}"
                rm -f "$WTAR"
            fi
        fi
        if [ -f "$WIN_PY_TARGET/python.exe" ]; then
            echo -e "  ${GREEN}✓${NC} Python (win-amd64) 下载完成"
        else
            echo -e "  ${CYAN}⚠${NC} Windows Python 下载或解压失败 (不影响当前平台)"
        fi
    fi

    WIN_ARM_PY_TARGET="$RUNTIME_DIR/python-win-arm64"
    WIN_ARM_PY_ASSET="cpython-${PY_CPYTHON_FULL}+${PY_STANDALONE_TAG}-aarch64-pc-windows-msvc-install_only.tar.gz"
    if [ -f "$WIN_ARM_PY_TARGET/python.exe" ]; then
        echo -e "  ${GREEN}✓${NC} Python (win-arm64) 已存在，跳过"
    else
        echo -e "  ${CYAN}↓${NC} 下载 Python ${PY_CPYTHON_FULL} (win-arm64)..."
        mkdir -p "$WIN_ARM_PY_TARGET"
        WURL_ARM="$PY_DOWNLOAD_BASE/$WIN_ARM_PY_ASSET"
        WTAR_ARM="/tmp/py-win-arm64-$$.tar.gz"
        if curl -fSL "$WURL_ARM" -o "$WTAR_ARM"; then
            if tar -xzf "$WTAR_ARM" -C "$WIN_ARM_PY_TARGET" --strip-components=1; then
                rm -f "$WTAR_ARM"
            else
                echo -e "    ${RED}✗ 解压 Windows ARM64 Python 失败${NC}"
                rm -f "$WTAR_ARM"
            fi
        fi
        if [ -f "$WIN_ARM_PY_TARGET/python.exe" ]; then
            echo -e "  ${GREEN}✓${NC} Python (win-arm64) 下载完成"
        else
            echo -e "  ${CYAN}⚠${NC} Windows ARM64 Python 下载或解压失败 (不影响当前平台)"
        fi
    fi
fi

# ---- 2. Install OpenClaw ----
if [ -d "$CORE_DIR/node_modules/openclaw" ]; then
    echo -e "  ${GREEN}✓${NC} OpenClaw 已安装，跳过"
else
    echo -e "  ${CYAN}↓${NC} 安装 OpenClaw..."
    mkdir -p "$CORE_DIR"

    # Init package.json if not exists
    if [ ! -f "$CORE_DIR/package.json" ]; then
        cat > "$CORE_DIR/package.json" << 'PKGJSON'
{
  "name": "u-claw-core",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "openclaw": "2026.5.4"
  }
}
PKGJSON
    fi

    # Install with China mirror
    NODE_BIN="$NODE_TARGET/bin/node"
    NPM_BIN="$NODE_TARGET/bin/npm"
    "$NODE_BIN" "$NPM_BIN" install --prefix "$CORE_DIR" --registry="$MIRROR"

    echo -e "  ${GREEN}✓${NC} OpenClaw 安装完成"
fi

# ---- 3. Install QQ Plugin ----
if [ -d "$CORE_DIR/node_modules/@sliverp/qqbot" ]; then
    echo -e "  ${GREEN}✓${NC} QQ 插件已安装，跳过"
else
    echo -e "  ${CYAN}↓${NC} 安装 QQ 插件..."
    NODE_BIN="$NODE_TARGET/bin/node"
    NPM_BIN="$NODE_TARGET/bin/npm"
    "$NODE_BIN" "$NPM_BIN" install @sliverp/qqbot@latest --prefix "$CORE_DIR" --registry="$MIRROR" 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} QQ 插件安装完成"
fi

# ---- 4. Install China-optimized skills ----
SKILLS_CN="$SCRIPT_DIR/skills-cn"
SKILLS_TARGET="$CORE_DIR/node_modules/openclaw/skills"

if [ -d "$SKILLS_CN" ] && [ -d "$SKILLS_TARGET" ]; then
    echo -e "  ${CYAN}↓${NC} 安装中国优化技能 (skills-cn)..."
    SKILL_COUNT=0
    for skill_dir in "$SKILLS_CN"/*/; do
        skill_name=$(basename "$skill_dir")
        if [ ! -d "$SKILLS_TARGET/$skill_name" ]; then
            cp -R "$skill_dir" "$SKILLS_TARGET/$skill_name"
            SKILL_COUNT=$((SKILL_COUNT + 1))
        fi
    done
    echo -e "  ${GREEN}✓${NC} 中国技能安装完成 (+$SKILL_COUNT 个)"
fi

# ---- 5. Install skills-ufc (same layout as skills-cn) ----
SKILLS_UFC="$SCRIPT_DIR/skills-ufc"

if [ -d "$SKILLS_UFC" ] && [ -d "$SKILLS_TARGET" ]; then
    echo -e "  ${CYAN}↓${NC} 安装 UFC 技能 (skills-ufc)..."
    SKILL_UFC_COUNT=0
    for skill_dir in "$SKILLS_UFC"/*/; do
        skill_name=$(basename "$skill_dir")
        if [ ! -d "$SKILLS_TARGET/$skill_name" ]; then
            cp -R "$skill_dir" "$SKILLS_TARGET/$skill_name"
            SKILL_UFC_COUNT=$((SKILL_UFC_COUNT + 1))
        fi
    done
    echo -e "  ${GREEN}✓${NC} UFC 技能安装完成 (+$SKILL_UFC_COUNT 个)"
fi

# ---- Done ----
echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅ 搭建完成！${NC}"
echo ""
echo -e "  启动方式:"
echo -e "    Mac:     ${CYAN}bash Mac-Start.command${NC}"
echo -e "    Windows: 双击 ${CYAN}Windows-Start.bat${NC}"
echo ""
echo -e "  目录结构:"
echo -e "    app/core/       ← OpenClaw + 依赖"
echo -e "    app/runtime/    ← Node.js $NODE_VERSION + Python ${PY_CPYTHON_FULL}"
echo -e "    data/           ← 运行后自动生成"
echo ""
echo -e "  ${CYAN}提示: 制作跨平台 U 盘请用 bash setup.sh --all-platforms${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
