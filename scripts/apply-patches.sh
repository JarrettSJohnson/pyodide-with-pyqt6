#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Apply .patch files to source trees
#
# Alternative to apply-wasm-patches.py — uses standard `patch` command with
# unified diff files from patches/.
#
# Usage:
#   ./scripts/apply-patches.sh [--pyqt6] [--pyodide] [--pyqtbuild] [--all]
#
# Prerequisites: sources must be downloaded first
# =============================================================================

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
SOURCES_DIR="$BUILD_DIR/sources"
PATCHES_DIR="$ROOT_DIR/patches"

# Version matrix (must match build.sh)
PYQT6_VERSION="6.10.2"
PYQT6_SRC="$SOURCES_DIR/pyqt6-${PYQT6_VERSION}"
PYODIDE_REPO="$SOURCES_DIR/pyodide"

log() { echo "==> $*"; }
err() { echo "ERROR: $*" >&2; exit 1; }

apply_patch() {
    local target_dir="$1"
    local patch_file="$2"
    local name="$3"

    if [ ! -f "$patch_file" ]; then
        log "  SKIP: $patch_file not found"
        return
    fi

    if [ ! -s "$patch_file" ]; then
        log "  SKIP: $patch_file is empty"
        return
    fi

    # Check if already applied (patch --dry-run -R succeeds if already applied)
    if patch -d "$target_dir" -p1 --dry-run -R < "$patch_file" >/dev/null 2>&1; then
        log "  $name: already applied"
        return
    fi

    patch -d "$target_dir" -p1 < "$patch_file"
    log "  $name: applied"
}

apply_pyqt6() {
    log "Applying PyQt6 patches..."
    [ -d "$PYQT6_SRC" ] || err "PyQt6 source not found at $PYQT6_SRC"

    apply_patch "$PYQT6_SRC" "$PATCHES_DIR/pyqt6-wasm-all.patch" "pyqt6-wasm-all"

    # Copy the timezone stub SIP file (new file, not a diff)
    local stub="$PATCHES_DIR/qtimezone_stub.sip"
    if [ -f "$stub" ]; then
        cp "$stub" "$PYQT6_SRC/sip/QtCore/qtimezone_stub.sip"
        log "  Copied qtimezone_stub.sip"
    fi
}

apply_pyqtbuild() {
    log "Applying pyqtbuild patches..."
    local bindings_py
    bindings_py="$(python -c 'import pyqtbuild; import os; print(os.path.dirname(pyqtbuild.__file__))')"
    apply_patch "$bindings_py" "$PATCHES_DIR/pyqtbuild-wasm-config-tests.patch" "pyqtbuild-wasm-config-tests"
}

apply_pyodide() {
    log "Applying Pyodide patches..."
    [ -d "$PYODIDE_REPO" ] || err "Pyodide source not found at $PYODIDE_REPO"

    apply_patch "$PYODIDE_REPO" "$PATCHES_DIR/pyodide-pyqt6-all.patch" "pyodide-pyqt6-all"
    apply_patch "$PYODIDE_REPO" "$PATCHES_DIR/pyodide-emsdk-ccache.patch" "pyodide-emsdk-ccache"
}

# =============================================================================
# Main
# =============================================================================
do_pyqt6=false
do_pyodide=false
do_pyqtbuild=false

if [ $# -eq 0 ] || [[ " $* " == *" --all "* ]]; then
    do_pyqt6=true
    do_pyodide=true
    do_pyqtbuild=true
else
    for arg in "$@"; do
        case "$arg" in
            --pyqt6)     do_pyqt6=true ;;
            --pyodide)   do_pyodide=true ;;
            --pyqtbuild) do_pyqtbuild=true ;;
            *) err "Unknown option: $arg. Use --pyqt6, --pyodide, --pyqtbuild, or --all" ;;
        esac
    done
fi

$do_pyqt6     && apply_pyqt6
$do_pyqtbuild && apply_pyqtbuild
$do_pyodide   && apply_pyodide

log "Done!"
