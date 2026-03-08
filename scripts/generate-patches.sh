#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Generate .patch files from the Python patching script
#
# This script:
#   1. Makes a clean copy of the source trees
#   2. Applies patches via apply-wasm-patches.py to the originals
#   3. Generates unified diffs as .patch files in patches/
#   4. Restores the originals (so build.sh can apply patches normally)
#
# Usage:
#   ./scripts/generate-patches.sh
#
# Prerequisites: sources must be downloaded (pixi run build downloads them)
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

# --- Validate sources exist ---
[ -d "$PYQT6_SRC" ] || err "PyQt6 source not found at $PYQT6_SRC"
[ -d "$PYODIDE_REPO" ] || err "Pyodide source not found at $PYODIDE_REPO"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# =============================================================================
# 1. PyQt6 SIP patches
# =============================================================================
generate_pyqt6_patches() {
    log "Generating PyQt6 patches..."

    # Get a clean copy of PyQt6 source for diffing.
    # The installed source may already be patched, so we download a fresh tarball.
    local clean_dir="$TMPDIR/pyqt6-clean"
    local tarball="$TMPDIR/PyQt6-${PYQT6_VERSION}.tar.gz"

    local cached_tarball="$SOURCES_DIR/pyqt6-${PYQT6_VERSION}.tar.gz"
    if [ -f "$cached_tarball" ]; then
        log "  Using cached tarball for clean PyQt6 source"
        cp "$cached_tarball" "$tarball"
    else
        log "  Downloading clean PyQt6 ${PYQT6_VERSION} for diffing..."
        wget -q -O "$tarball" \
            "https://files.pythonhosted.org/packages/source/P/PyQt6/pyqt6-${PYQT6_VERSION}.tar.gz"
    fi
    mkdir -p "$clean_dir"
    tar xzf "$tarball" -C "$clean_dir" --strip-components=1

    # The patched source is our current source tree (may already be patched).
    # If not yet patched, apply patches first.
    local patched_dir="$TMPDIR/pyqt6-patched"
    cp -a "$PYQT6_SRC" "$patched_dir"
    python "$PATCHES_DIR/apply-wasm-patches.py" "$patched_dir"

    # Files that get patched
    local files=(
        "sip/QtCore/QtCoremod.sip"
        "sip/QtCore/qtimezone.sip"
        "sip/QtCore/qdatetime.sip"
        "sip/QtCore/qfileinfo.sip"
        "sip/QtCore/qprocess.sip"
        "sip/QtCore/qobject.sip"
        "sip/QtCore/qabstracteventdispatcher.sip"
        "sip/QtCore/qeventloop.sip"
        "sip/QtCore/qcoreapplication.sip"
        "qpy/QtCore/qpycore_public_api.cpp"
        "qpy/QtCore/qpycore_pyqtmutexlocker.cpp"
        "qpy/QtCore/qpycore_pyqtmutexlocker.h"
    )

    # Generate diffs
    local patch_file="$PATCHES_DIR/pyqt6-wasm-all.patch"
    > "$patch_file"
    for f in "${files[@]}"; do
        if [ -f "$clean_dir/$f" ] && [ -f "$patched_dir/$f" ]; then
            diff -u "$clean_dir/$f" "$patched_dir/$f" \
                | sed "s|$clean_dir/|a/|g; s|$patched_dir/|b/|g" \
                >> "$patch_file" || true  # diff returns 1 when files differ
        fi
    done

    log "  Wrote $patch_file"
}

# =============================================================================
# 2. pyqtbuild patches
# =============================================================================
generate_pyqtbuild_patch() {
    log "Generating pyqtbuild patch..."

    local bindings_py
    bindings_py="$(python -c 'import pyqtbuild; import os; print(os.path.join(os.path.dirname(pyqtbuild.__file__), "bindings.py"))')"

    if [ ! -f "$bindings_py" ]; then
        log "  pyqtbuild not installed, skipping"
        return
    fi

    local clean_copy="$TMPDIR/bindings-clean.py"
    local patched_copy="$TMPDIR/bindings-patched.py"
    cp "$bindings_py" "$clean_copy"
    cp "$bindings_py" "$patched_copy"

    # Apply patch to the copy by invoking the patch function directly
    python -c "
import sys; sys.path.insert(0, '$PATCHES_DIR')
from pathlib import Path
import importlib.util
spec = importlib.util.spec_from_file_location('patches', '$PATCHES_DIR/apply-wasm-patches.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.patch_pyqtbuild(Path('$patched_copy'))
"

    local patch_file="$PATCHES_DIR/pyqtbuild-wasm-config-tests.patch"
    diff -u "$clean_copy" "$patched_copy" \
        | sed "s|$clean_copy|a/pyqtbuild/bindings.py|g; s|$patched_copy|b/pyqtbuild/bindings.py|g" \
        > "$patch_file" || true

    log "  Wrote $patch_file"
}

# =============================================================================
# 3. Pyodide patches
# =============================================================================
generate_pyodide_patches() {
    log "Generating Pyodide patches..."

    local files=(
        "src/core/main.c"
        "Makefile.envs"
    )

    # Use git to get clean versions (Pyodide is a git clone)
    local clean_dir="$TMPDIR/pyodide-clean"
    mkdir -p "$clean_dir"
    for f in "${files[@]}"; do
        if [ -f "$PYODIDE_REPO/$f" ]; then
            mkdir -p "$clean_dir/$(dirname "$f")"
            git -C "$PYODIDE_REPO" show "HEAD:$f" > "$clean_dir/$f" 2>/dev/null \
                || cp "$PYODIDE_REPO/$f" "$clean_dir/$f"
        fi
    done

    # Apply patches to a copy
    local patched_dir="$TMPDIR/pyodide-patched"
    mkdir -p "$patched_dir"
    for f in "${files[@]}"; do
        mkdir -p "$patched_dir/$(dirname "$f")"
        cp "$clean_dir/$f" "$patched_dir/$f"
    done
    # We need a minimal "pyodide repo" structure for the patch script
    cp -a "$PYODIDE_REPO/src" "$patched_dir/src" 2>/dev/null || true
    cp "$PYODIDE_REPO/Makefile.envs" "$patched_dir/Makefile.envs" 2>/dev/null || true
    # Reset to clean
    for f in "${files[@]}"; do
        cp "$clean_dir/$f" "$patched_dir/$f"
    done

    python3 "$PATCHES_DIR/apply-wasm-patches.py" \
        --pyodide "$patched_dir" \
        --build-dir "$BUILD_DIR"

    local patch_file="$PATCHES_DIR/pyodide-pyqt6-all.patch"
    > "$patch_file"
    for f in "${files[@]}"; do
        if [ -f "$clean_dir/$f" ] && [ -f "$patched_dir/$f" ]; then
            diff -u "$clean_dir/$f" "$patched_dir/$f" \
                | sed "s|$clean_dir/|a/|g; s|$patched_dir/|b/|g" \
                >> "$patch_file" || true
        fi
    done

    log "  Wrote $patch_file"
}

# =============================================================================
# 4. Pyodide emsdk patches (sed-based, from build.sh)
# =============================================================================
generate_pyodide_emsdk_patch() {
    log "Generating Pyodide emsdk patch..."

    local files=(
        "emsdk/Makefile"
        "pyodide_env.sh"
    )

    # Use git to get clean versions
    local clean_dir="$TMPDIR/pyodide-emsdk-clean"
    local patched_dir="$TMPDIR/pyodide-emsdk-patched"
    mkdir -p "$clean_dir/emsdk" "$patched_dir/emsdk"
    for f in "${files[@]}"; do
        git -C "$PYODIDE_REPO" show "HEAD:$f" > "$clean_dir/$f" 2>/dev/null \
            || cp "$PYODIDE_REPO/$f" "$clean_dir/$f"
        cp "$clean_dir/$f" "$patched_dir/$f"
    done

    # Apply the sed patches to copies (use temp file for portability)
    grep -v 'ccache-git-emscripten-64bit' "$patched_dir/emsdk/Makefile" > "$patched_dir/emsdk/Makefile.tmp"
    mv "$patched_dir/emsdk/Makefile.tmp" "$patched_dir/emsdk/Makefile"
    sed 's|export _EMCC_CCACHE=1|command -v ccache >/dev/null 2>\&1 \&\& export _EMCC_CCACHE=1|' "$patched_dir/pyodide_env.sh" > "$patched_dir/pyodide_env.sh.tmp"
    mv "$patched_dir/pyodide_env.sh.tmp" "$patched_dir/pyodide_env.sh"

    local patch_file="$PATCHES_DIR/pyodide-emsdk-ccache.patch"
    > "$patch_file"
    for f in "${files[@]}"; do
        diff -u "$clean_dir/$f" "$patched_dir/$f" \
            | sed "s|$clean_dir/|a/|g; s|$patched_dir/|b/|g" \
            >> "$patch_file" || true
    done

    log "  Wrote $patch_file"
}

# =============================================================================
# Main
# =============================================================================
log "Generating patch files..."
generate_pyqt6_patches
generate_pyqtbuild_patch
generate_pyodide_patches
generate_pyodide_emsdk_patch
log "Done! Patch files saved to $PATCHES_DIR/"
ls -la "$PATCHES_DIR"/*.patch
