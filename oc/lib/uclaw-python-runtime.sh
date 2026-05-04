#!/bin/bash
# Portable CPython 3.12 (astral-sh/python-build-standalone install_only layout).
# Sourced by U盘虾 launchers after APP_DIR（及 ARCH）已设置。
# Windows 不能 source 本文件；pip 镜像常量请与 oc/lib/uclaw-pip-mirror.bat 保持同步。
# PATH 置顶（便携 Python + Node）：本文件的 uclaw_export_path_portable_first；Windows 用 oc/lib/uclaw-portable-path.bat。

UCLAW_PY_STANDALONE_TAG="${UCLAW_PY_STANDALONE_TAG:-20260303}"
UCLAW_PY_CPYTHON_FULL="${UCLAW_PY_CPYTHON_FULL:-3.12.13}"
UCLAW_PY_DOWNLOAD_BASE="https://registry.npmmirror.com/-/binary/python-build-standalone/${UCLAW_PY_STANDALONE_TAG}"

uclaw_ensure_portable_pip_conf() {
  local pydir="$1" cf
  [ -n "$pydir" ] || return 0
  [ -x "$pydir/bin/python3" ] || return 0
  cf="$pydir/uclaw-pip.conf"
  cat >"$cf" <<'EOF'
[global]
index-url = https://mirrors.aliyun.com/pypi/simple/
trusted-host = mirrors.aliyun.com
timeout = 120
EOF
  export PIP_CONFIG_FILE="$cf"
}

uclaw_python_asset_for_arch() {
  case "${1:-}" in
    arm64) echo "cpython-${UCLAW_PY_CPYTHON_FULL}+${UCLAW_PY_STANDALONE_TAG}-aarch64-apple-darwin-install_only.tar.gz" ;;
    x86_64) echo "cpython-${UCLAW_PY_CPYTHON_FULL}+${UCLAW_PY_STANDALONE_TAG}-x86_64-apple-darwin-install_only.tar.gz" ;;
    *) echo "" ;;
  esac
}

uclaw_python_runtime_export() {
  local app_dir="$1"
  local arch="${2:-$(uname -m)}"
  if [ "$arch" = "arm64" ]; then
    PYTHON_DIR="${app_dir}/runtime/python-mac-arm64"
  else
    PYTHON_DIR="${app_dir}/runtime/python-mac-x64"
  fi
  PYTHON_BIN="$PYTHON_DIR/bin/python3"
  if [ ! -x "$PYTHON_BIN" ] && [ -x "${app_dir}/runtime/python-mac-arm64/bin/python3" ]; then
    PYTHON_DIR="${app_dir}/runtime/python-mac-arm64"
    PYTHON_BIN="$PYTHON_DIR/bin/python3"
  fi
  if [ ! -x "$PYTHON_BIN" ] && [ -x "${app_dir}/runtime/python-mac-x64/bin/python3" ]; then
    PYTHON_DIR="${app_dir}/runtime/python-mac-x64"
    PYTHON_BIN="$PYTHON_DIR/bin/python3"
  fi
  export PYTHON_DIR PYTHON_BIN
  if [ -x "${PYTHON_DIR}/bin/python3" ]; then
    uclaw_ensure_portable_pip_conf "$PYTHON_DIR"
  fi
}

# Put portable Python then Node bin dirs at the **front** of PATH and remove duplicate
# entries so Homebrew /usr/local/bin cannot shadow python3/pip3 from this bundle.
# Args: optional python install root, optional node install root (e.g. .../python-mac-x64).
uclaw_export_path_portable_first() {
  local py_root="${1:-}" nd_root="${2:-}"
  local py_bin="" nd_bin=""

  if [ -n "$py_root" ]; then
    py_root="${py_root%/}"
    if [ -x "$py_root/bin/python3" ]; then
      py_bin="$py_root/bin"
    fi
  fi
  if [ -n "$nd_root" ]; then
    nd_root="${nd_root%/}"
    if [ -x "$nd_root/bin/node" ]; then
      nd_bin="$nd_root/bin"
    fi
  fi

  local filtered="" part rest="$PATH"
  while [ -n "$rest" ]; do
    case "$rest" in
      *:*) part="${rest%%:*}"; rest="${rest#*:}" ;;
      *) part="$rest"; rest="" ;;
    esac
    [ -z "$part" ] && continue
    [ "$part" = "$py_bin" ] && continue
    [ "$part" = "$nd_bin" ] && continue
    if [ -n "$filtered" ]; then
      filtered="$filtered:$part"
    else
      filtered="$part"
    fi
  done

  local head=""
  [ -n "$py_bin" ] && head="$py_bin:"
  [ -n "$nd_bin" ] && head="${head}$nd_bin:"
  export PATH="${head}${filtered}"
}

# Download + extract install_only tarball into PYTHON_DIR (darwin).
uclaw_bootstrap_python_mac() {
  local app_dir="$1"
  local arch="${2:-$(uname -m)}"
  uclaw_python_runtime_export "$app_dir" "$arch"
  if [ -x "$PYTHON_BIN" ]; then
    return 0
  fi
  local asset
  asset="$(uclaw_python_asset_for_arch "$arch")"
  if [ -z "$asset" ]; then
    return 1
  fi
  local url="${UCLAW_PY_DOWNLOAD_BASE}/${asset}"
  local tmp="/tmp/${asset}"
  mkdir -p "$PYTHON_DIR"
  if ! curl -fL --connect-timeout 20 --retry 2 "$url" -o "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! tar -xzf "$tmp" -C "$PYTHON_DIR" --strip-components=1; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  chmod -R u+w "$PYTHON_DIR" 2>/dev/null || true
  chmod +x "$PYTHON_DIR/bin/python3" 2>/dev/null || true
  PYTHON_BIN="$PYTHON_DIR/bin/python3"
  if [ ! -x "$PYTHON_BIN" ]; then
    return 1
  fi
  uclaw_ensure_portable_pip_conf "$PYTHON_DIR"
  return 0
}

# PyPI 镜像：写死阿里云（与 oc/lib/uclaw-pip-mirror.bat 一致）；便携目录内另有 uclaw-pip.conf + PIP_CONFIG_FILE
uclaw_pip_mirror_export() {
  export PIP_INDEX_URL="https://mirrors.aliyun.com/pypi/simple/"
  export PIP_TRUSTED_HOST="mirrors.aliyun.com"
  export PIP_DEFAULT_TIMEOUT="120"
}

uclaw_pip_mirror_export
