#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$ROOT_DIR/dist"
BASE_REF="HEAD"
TARGET_REF="--working"
PATCH_NAME="u-fresh-claw-hotfix-$(date +%Y%m%d_%H%M%S)"
WITH_PATCH=0

EXCLUDES=(
  "make-hotfix-patch.sh"
  "release.sh"
  "create-img.sh"
  "extract-zip-to-usb.sh"
)

usage() {
  cat <<'USAGE'
Usage:
  ./make-hotfix-patch.sh [options]

Options:
  --base REF       Base git ref to diff from. Default: HEAD
  --target REF     Target git ref to diff to. Default: working tree
  --working        Use working tree as target. Default
  --name NAME      Output package name. Default: u-fresh-claw-hotfix-YYYYMMDD_HHMMSS
  --out DIR        Output directory. Default: ./dist
  --exclude PATH   Exclude a changed path from the patch package. Can be repeated.
  --with-patch     Also write a git-apply patch file into the package directory.
  -h, --help       Show help.

Outputs:
  dist/<name>/overlay/...      Runtime files that can be copied over an existing install
  dist/<name>.zip              User package containing overlay + README
  dist/<name>.zip.sha256

Examples:
  ./make-hotfix-patch.sh --name u-fresh-claw-hotfix-weixin
  ./make-hotfix-patch.sh --base v0.0.7 --target hotfix/weixin --name u-fresh-claw-hotfix-weixin
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base)
      BASE_REF="${2:-}"
      [ -n "$BASE_REF" ] || { echo "ERROR: --base requires a value" >&2; exit 1; }
      shift 2
      ;;
    --target)
      TARGET_REF="${2:-}"
      [ -n "$TARGET_REF" ] || { echo "ERROR: --target requires a value" >&2; exit 1; }
      shift 2
      ;;
    --working)
      TARGET_REF="--working"
      shift
      ;;
    --name)
      PATCH_NAME="${2:-}"
      [ -n "$PATCH_NAME" ] || { echo "ERROR: --name requires a value" >&2; exit 1; }
      shift 2
      ;;
    --out)
      OUT_DIR="${2:-}"
      [ -n "$OUT_DIR" ] || { echo "ERROR: --out requires a value" >&2; exit 1; }
      shift 2
      ;;
    --exclude)
      exclude_path="${2:-}"
      [ -n "$exclude_path" ] || { echo "ERROR: --exclude requires a value" >&2; exit 1; }
      EXCLUDES+=("$exclude_path")
      shift 2
      ;;
    --with-patch)
      WITH_PATCH=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

cd "$ROOT_DIR"

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "ERROR: not inside a git repository" >&2
  exit 1
fi

if ! git rev-parse --verify "$BASE_REF^{commit}" >/dev/null 2>&1; then
  echo "ERROR: base ref not found: $BASE_REF" >&2
  exit 1
fi

if [ "$TARGET_REF" != "--working" ] && ! git rev-parse --verify "$TARGET_REF^{commit}" >/dev/null 2>&1; then
  echo "ERROR: target ref not found: $TARGET_REF" >&2
  exit 1
fi

is_excluded() {
  local path="$1"
  local ex
  for ex in "${EXCLUDES[@]}"; do
    [ "$path" = "$ex" ] && return 0
  done
  [[ "$path" == dist/* ]] && return 0
  [[ "$path" == .git/* ]] && return 0
  return 1
}

collect_changed_files() {
  if [ "$TARGET_REF" = "--working" ]; then
    git diff -z --name-only --diff-filter=ACMRT "$BASE_REF" --
  else
    git diff -z --name-only --diff-filter=ACMRT "$BASE_REF" "$TARGET_REF" --
  fi
}

CHANGED_FILES=()
while IFS= read -r -d '' file; do
  [ -n "$file" ] || continue
  if is_excluded "$file"; then
    continue
  fi
  CHANGED_FILES+=("$file")
done < <(collect_changed_files)

if [ "${#CHANGED_FILES[@]}" -eq 0 ]; then
  echo "ERROR: no changed files after exclusions" >&2
  exit 1
fi

PKG_DIR="$OUT_DIR/$PATCH_NAME"
OVERLAY_DIR="$PKG_DIR/overlay"
PATCH_FILE="$PKG_DIR/$PATCH_NAME.patch"
ZIP_FILE="$OUT_DIR/$PATCH_NAME.zip"
SHA_FILE="$ZIP_FILE.sha256"

rm -rf "$PKG_DIR" "$ZIP_FILE" "$SHA_FILE"
mkdir -p "$OVERLAY_DIR"

if [ "$WITH_PATCH" = "1" ]; then
  if [ "$TARGET_REF" = "--working" ]; then
    git diff --binary "$BASE_REF" -- "${CHANGED_FILES[@]}" > "$PATCH_FILE"
  else
    git diff --binary "$BASE_REF" "$TARGET_REF" -- "${CHANGED_FILES[@]}" > "$PATCH_FILE"
  fi
fi

for file in "${CHANGED_FILES[@]}"; do
  mkdir -p "$OVERLAY_DIR/$(dirname "$file")"
  if [ "$TARGET_REF" = "--working" ]; then
    cp -p "$file" "$OVERLAY_DIR/$file"
  else
    git show "$TARGET_REF:$file" > "$OVERLAY_DIR/$file"
    mode="$(git ls-tree "$TARGET_REF" -- "$file" | awk '{print $1}')"
    if [ "$mode" = "100755" ]; then
      chmod +x "$OVERLAY_DIR/$file"
    fi
  fi
done

{
  echo "# $PATCH_NAME"
  echo
  echo "Base: $BASE_REF"
  echo "Target: $TARGET_REF"
  echo
  echo "## Included files"
  for file in "${CHANGED_FILES[@]}"; do
    echo "- $file"
  done
  echo
  echo "## Overlay install"
  echo "Copy the contents of overlay/ to the UFreshClaw root directory, preserving paths."
  if [ "$WITH_PATCH" = "1" ]; then
    echo
    echo "## Git patch install"
    echo "From the repository root:"
    echo
    echo '```bash'
    echo "git apply \"$PATCH_FILE\""
    echo '```'
  fi
} > "$PKG_DIR/README.md"

mkdir -p "$OUT_DIR"
(
  cd "$PKG_DIR"
  zip -qr "../$PATCH_NAME.zip" .
)

if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$ZIP_FILE" > "$SHA_FILE"
elif command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$ZIP_FILE" > "$SHA_FILE"
else
  echo "WARN: no sha256 tool found; skipped checksum" >&2
fi

echo "Created:"
echo "  Package: $ZIP_FILE"
if [ "$WITH_PATCH" = "1" ]; then
  echo "  Patch  : $PATCH_FILE"
fi
[ -f "$SHA_FILE" ] && echo "  SHA256 : $SHA_FILE"
echo
echo "Included files:"
printf '  %s\n' "${CHANGED_FILES[@]}"
