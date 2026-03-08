#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# PyQt6 on Pyodide — Build Script
# =============================================================================
#
# Usage:
#   pixi run build          # full build
#   pixi run build-qt       # Qt6 WASM only
#   pixi run build-pyqt     # SIP + PyQt6 only
#   pixi run build-pyodide  # link into Pyodide only
#   pixi run clean          # remove build artifacts
#
# Prerequisites: run inside pixi environment (pixi run build)
# =============================================================================

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
SOURCES_DIR="$BUILD_DIR/sources"
PATCHES_DIR="$ROOT_DIR/patches"
OUTPUT_DIR="$BUILD_DIR/output"

# Version matrix — keep these in sync
QT_VERSION="6.10.2"
QT_BRANCH="v${QT_VERSION}"
PYQT6_VERSION="6.10.2"
SIP_VERSION="6.15.1"
PYQT6_SIP_VERSION="13.11.0"
PYODIDE_VERSION="main"  # branch or tag to clone

# Derived paths
QT_SRC="$SOURCES_DIR/qt6"
QT_INSTALL="$BUILD_DIR/qt6-wasm"
PYQT6_SRC="$SOURCES_DIR/pyqt6-${PYQT6_VERSION}"
SIP_SRC="$SOURCES_DIR/sip-${SIP_VERSION}"
PYODIDE_SRC="$SOURCES_DIR/pyodide"
PYODIDE_REPO="$PYODIDE_SRC"

# ---- Helpers ----------------------------------------------------------------

log() { echo "==> $*"; }
err() { echo "ERROR: $*" >&2; exit 1; }

# ---- Pyodide emsdk setup ---------------------------------------------------
# All builds (Qt, PyQt6, Pyodide) MUST use the same Emscripten to ensure ABI
# compatibility (exception handling, longjmp, PIC relocations).
# Pyodide builds its own emsdk with specific flags (-fwasm-exceptions, etc.)
# so we use that emsdk for everything.

clone_pyodide() {
    mkdir -p "$SOURCES_DIR"
    if [ ! -d "$PYODIDE_REPO" ]; then
        log "Cloning Pyodide..."
        git clone --depth 1 --branch "$PYODIDE_VERSION" \
            https://github.com/pyodide/pyodide.git "$PYODIDE_REPO"
    fi
}

patch_pyodide_emsdk() {
    # Patch emsdk to skip ccache (ccache build fails with newer CMake)
    log "Patching emsdk to skip ccache..."
    sed -i '/ccache-git-emscripten-64bit/d' "$PYODIDE_REPO/emsdk/Makefile"
    # pyodide_env.sh unconditionally sets _EMCC_CCACHE=1, making emcc exec
    # through ccache even when it's not installed. Only enable if available.
    sed -i 's|export _EMCC_CCACHE=1|command -v ccache >/dev/null 2>\&1 \&\& export _EMCC_CCACHE=1|' "$PYODIDE_REPO/pyodide_env.sh"
}

setup_pyodide_emsdk() {
    clone_pyodide
    patch_pyodide_emsdk

    local emsdk_dir="$PYODIDE_REPO/emsdk/emsdk"
    if [ ! -f "$emsdk_dir/upstream/emscripten/emcc.py" ]; then
        log "Building Pyodide's emsdk..."
        pushd "$PYODIDE_REPO"
        export PYODIDE_ROOT="$(pwd)"
        unset EMSDK EM_CONFIG EMSDK_NODE EMSDK_PYTHON PYTHON 2>/dev/null || true
        make emsdk/emsdk/.complete
        popd
    fi

    # Source emsdk environment
    log "Activating Pyodide's emsdk..."
    export EMSDK="$emsdk_dir"
    export EM_CONFIG="$emsdk_dir/.emscripten"
    export PATH="$emsdk_dir/upstream/emscripten:$emsdk_dir/upstream/bin:$emsdk_dir/node/22.16.0_64bit/bin:$PATH"

    # Verify
    local em_ver
    em_ver=$(emcc --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    log "Using Pyodide's Emscripten: $em_ver"
}

# ---- Phase 1: Build Qt6 for WASM -------------------------------------------

build_qt() {
    log "Phase 1: Building Qt6 $QT_VERSION for WebAssembly"
    setup_pyodide_emsdk
    mkdir -p "$SOURCES_DIR"

    # Clone Qt6 if needed
    if [ ! -d "$QT_SRC" ]; then
        log "Cloning Qt6..."
        git clone --branch "$QT_BRANCH" --depth 1 \
            https://code.qt.io/qt/qt5.git "$QT_SRC"
        pushd "$QT_SRC"
        # Only init the modules we need
        perl init-repository --module-subset=qtbase,qtsvg
        popd
    fi

    # Configure
    if [ ! -f "$QT_SRC/build-wasm/config.summary" ]; then
        log "Configuring Qt6 for wasm-emscripten..."
        mkdir -p "$QT_SRC/build-wasm"
        pushd "$QT_SRC/build-wasm"
        "$QT_SRC/configure" \
            -qt-host-path "$CONDA_PREFIX" \
            -platform wasm-emscripten \
            -static \
            -prefix "$QT_INSTALL" \
            -no-feature-thread \
            -feature-wasm-exceptions \
            -opensource \
            -confirm-license \
            -nomake examples \
            -nomake tests \
            -no-warnings-are-errors
        popd
    fi

    # Build
    log "Building Qt6 (this will take a while)..."
    pushd "$QT_SRC/build-wasm"
    cmake --build . --parallel
    cmake --install .
    popd

    log "Qt6 WASM build complete: $QT_INSTALL"
}

# ---- Source downloads -------------------------------------------------------

download_sources() {
    mkdir -p "$SOURCES_DIR"

    # PyQt6 source tarball (no public git repo — distributed via PyPI)
    if [ ! -d "$PYQT6_SRC" ]; then
        local pyqt6_tarball="$SOURCES_DIR/pyqt6-${PYQT6_VERSION}.tar.gz"
        if [ ! -f "$pyqt6_tarball" ]; then
            log "Downloading PyQt6 ${PYQT6_VERSION} from PyPI..."
            wget -q -O "$pyqt6_tarball" \
                "https://files.pythonhosted.org/packages/source/P/PyQt6/pyqt6-${PYQT6_VERSION}.tar.gz"
        fi
        log "Extracting PyQt6..."
        tar xzf "$pyqt6_tarball" -C "$SOURCES_DIR"
    fi

    # PyQt6-sip source tarball
    if [ ! -d "$SOURCES_DIR/pyqt6_sip-${PYQT6_SIP_VERSION}" ]; then
        local sip_tarball="$SOURCES_DIR/pyqt6_sip-${PYQT6_SIP_VERSION}.tar.gz"
        if [ ! -f "$sip_tarball" ]; then
            log "Downloading PyQt6-sip ${PYQT6_SIP_VERSION} from PyPI..."
            wget -q -O "$sip_tarball" \
                "https://files.pythonhosted.org/packages/source/P/PyQt6-sip/pyqt6_sip-${PYQT6_SIP_VERSION}.tar.gz"
        fi
        log "Extracting PyQt6-sip..."
        tar xzf "$sip_tarball" -C "$SOURCES_DIR"
    fi
}

# ---- Phase 2: Build SIP + PyQt6 for WASM -----------------------------------

PYQT6_SIP_SRC="$SOURCES_DIR/pyqt6_sip-${PYQT6_SIP_VERSION}"

# Build Pyodide's cross-compiled CPython (needed for Python.h headers)
build_cpython() {
    local pyversion pymajmin pyodide_lib
    pyversion=$(grep 'PYVERSION' "$PYODIDE_REPO/Makefile.envs" | head -1 | sed 's/.*?= *//')
    pymajmin="${pyversion%.*}"
    pyodide_lib="$PYODIDE_REPO/cpython/installs/python-${pyversion}/lib/python${pymajmin}"

    if [ ! -d "$pyodide_lib" ]; then
        log "Building Pyodide's CPython (needed for Python headers)..."
        pushd "$PYODIDE_REPO"
        export PYODIDE_ROOT="$(pwd)"
        make "$pyodide_lib"
        popd
    fi
}

# Get Pyodide's cross-compilation paths
get_pyodide_paths() {
    PYODIDE_PYTHON_INCLUDE=$(pixi run pyodide config get python_include_dir)
    PYODIDE_PYTHON_LIB=$(dirname "$PYODIDE_PYTHON_INCLUDE")/../lib
    PYODIDE_CFLAGS=$(pixi run pyodide config get cflags)
    PYODIDE_LDFLAGS=$(pixi run pyodide config get ldflags)
    log "Pyodide Python include: $PYODIDE_PYTHON_INCLUDE"
}

build_pyqt_sip() {
    log "Phase 2a: Building PyQt6-sip (C extension) with emcc"
    get_pyodide_paths

    if [ ! -d "$PYQT6_SIP_SRC" ]; then
        err "PyQt6-sip source not found at $PYQT6_SIP_SRC — run download_sources first"
    fi

    local sip_build_dir="$BUILD_DIR/pyqt6-sip-build"
    mkdir -p "$sip_build_dir"

    # Compile each .c file with emcc
    local sip_c_files=(
        sip_core.c sip_array.c sip_descriptors.c sip_enum.c
        sip_int_convertors.c sip_object_map.c sip_threads.c sip_voidptr.c
    )

    for src in "${sip_c_files[@]}"; do
        log "  Compiling $src..."
        emcc \
            -fPIC \
            $PYODIDE_CFLAGS \
            -DSIP_STATIC_MODULE=1 \
            -I"$PYODIDE_PYTHON_INCLUDE" \
            -I"$PYQT6_SIP_SRC" \
            -c "$PYQT6_SIP_SRC/$src" \
            -o "$sip_build_dir/${src%.c}.o"
    done

    # Create static library (remove old archive first — emar q appends)
    rm -f "$sip_build_dir/libsip.a"
    emar crs "$sip_build_dir/libsip.a" "$sip_build_dir"/*.o
    log "Built: $sip_build_dir/libsip.a"
}

build_pyqt_modules() {
    log "Phase 2b: Building PyQt6 modules with emcc"
    setup_pyodide_emsdk
    get_pyodide_paths

    if [ ! -d "$PYQT6_SRC" ]; then
        err "PyQt6 source not found at $PYQT6_SRC — download and extract it first"
    fi

    # Apply WASM patches to PyQt6 SIP files and pyqt-builder
    log "Applying WASM patches..."
    local bindings_py
    bindings_py="$(python -c 'import pyqtbuild; import os; print(os.path.join(os.path.dirname(pyqtbuild.__file__), "bindings.py"))')"
    python "$PATCHES_DIR/apply-wasm-patches.py" "$PYQT6_SRC" "$bindings_py"

    local pyqt_build_dir="$BUILD_DIR/pyqt6-build"
    mkdir -p "$pyqt_build_dir"

    # Step 1: Use sip-build to generate C++ source
    log "Running sip-build --no-make to generate C++ source..."
    pushd "$PYQT6_SRC"

    # Point qmake at our WASM Qt6 build
    export PATH="$QT_INSTALL/bin:$PATH"
    export QMAKE="$QT_INSTALL/bin/qmake6"

    # WASM cross-compilation: can't run config test executables on host.
    export PYQT_WASM_FEATURES="QtCore=static,PyQt_Process,PyQt_Timezone,PyQt_SystemSemaphore,PyQt_Thread;QtGui=PyQt_XCB,PyQt_Wayland,PyQt_Vulkan;QtWidgets=;QtSvg=;QtSvgWidgets="

    sip-build \
        --verbose \
        --confirm-license \
        --no-make \
        --build-dir "$pyqt_build_dir" \
        --no-designer-plugin \
        --no-qml-plugin \
        --no-dbus-python \
        --no-tools \
        --disable QtDBus \
        --disable QtDesigner \
        --disable QtHelp \
        --disable QtMultimedia \
        --disable QtMultimediaWidgets \
        --disable QtNetwork \
        --disable QtNfc \
        --disable QtOpenGL \
        --disable QtOpenGLWidgets \
        --disable QtPdf \
        --disable QtPdfWidgets \
        --disable QtPositioning \
        --disable QtPrintSupport \
        --disable QtQml \
        --disable QtQuick \
        --disable QtQuick3D \
        --disable QtQuickWidgets \
        --disable QtRemoteObjects \
        --disable QtSensors \
        --disable QtSerialPort \
        --disable QtSpatialAudio \
        --disable QtSql \
        --disable QtStateMachine \
        --disable QtTest \
        --disable QtTextToSpeech \
        --disable QtWebChannel \
        --disable QtWebSockets \
        --disable QtBluetooth \
        --disable QAxContainer \
        2>&1 || true

    popd

    # Step 2: Fix Python include paths and add -fPIC
    log "Replacing host Python include with Pyodide include ($PYODIDE_PYTHON_INCLUDE)..."
    local host_py_include
    host_py_include="$(python -c 'import sysconfig; print(sysconfig.get_path("include"))')"
    find "$pyqt_build_dir" -name Makefile | while read -r mf; do
        local mf_dir
        mf_dir="$(dirname "$mf")"
        local rel_path
        rel_path="$(python -c "import os; print(os.path.relpath('$host_py_include', '$mf_dir'))")"
        sed -i "s|$rel_path|$PYODIDE_PYTHON_INCLUDE|g" "$mf"
        sed -i "s|$host_py_include|$PYODIDE_PYTHON_INCLUDE|g" "$mf"
        # Add -fPIC for MAIN_MODULE=1 dynamic linking compatibility
        sed -i 's/^CFLAGS\s*=\(.*\)/CFLAGS        = -fPIC\1/' "$mf"
        sed -i 's/^CXXFLAGS\s*=\(.*\)/CXXFLAGS      = -fPIC\1/' "$mf"
    done

    # Step 3: Build using the generated Makefiles (qmake already configured em++)
    log "Building PyQt6 modules with make..."
    pushd "$pyqt_build_dir"
    make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)" 2>&1
    popd

    log "PyQt6 modules build complete"
}

build_pyqt() {
    log "Phase 2: Building SIP + PyQt6 for WebAssembly"
    setup_pyodide_emsdk
    download_sources
    build_cpython
    build_pyqt_sip
    build_pyqt_modules
}

# ---- Phase 3: Link into Pyodide --------------------------------------------

build_pyodide() {
    log "Phase 3: Building Pyodide with PyQt6"
    setup_pyodide_emsdk

    if [ ! -d "$PYODIDE_REPO/src/core" ]; then
        err "Pyodide source not found at $PYODIDE_REPO"
    fi

    mkdir -p "$OUTPUT_DIR"

    # Step 1: Generate link flags file (needed before patching Makefile.envs)
    log "Generating link flags..."
    local qt_lib="$QT_INSTALL/lib"
    local qt_plugins="$QT_INSTALL/plugins"
    local pyqt_build="$BUILD_DIR/pyqt6-build"
    local sip_build="$BUILD_DIR/pyqt6-sip-build"
    local qt_objects="$QT_INSTALL/lib/objects-Release"

    cat > "$BUILD_DIR/pyqt6-ldflags.txt" <<LDFLAGS
# PyQt6 module libraries
$pyqt_build/QtCore/libQtCore.a
$pyqt_build/QtGui/libQtGui.a
$pyqt_build/QtWidgets/libQtWidgets.a
$pyqt_build/QtSvg/libQtSvg.a
$pyqt_build/QtSvgWidgets/libQtSvgWidgets.a
$pyqt_build/QtXml/libQtXml.a
$sip_build/libsip.a

# Qt plugin import object and threading stubs
$BUILD_DIR/qt_plugin_import.o
$BUILD_DIR/qt_wasm_stubs.o

# Qt6 static libraries
$qt_lib/libQt6Widgets.a
$qt_lib/libQt6Gui.a
$qt_lib/libQt6Core.a
$qt_lib/libQt6Svg.a
$qt_lib/libQt6SvgWidgets.a
$qt_lib/libQt6Xml.a
$qt_lib/libQt6OpenGL.a

# Qt6 bundled third-party libs
$qt_lib/libQt6BundledHarfbuzz.a
$qt_lib/libQt6BundledFreetype.a
$qt_lib/libQt6BundledLibpng.a
$qt_lib/libQt6BundledLibjpeg.a
$qt_lib/libQt6BundledPcre2.a
$qt_lib/libQt6BundledZLIB.a

# Qt6 plugins
$qt_plugins/platforms/libqwasm.a
$qt_plugins/iconengines/libqsvgicon.a
$qt_plugins/imageformats/libqgif.a
$qt_plugins/imageformats/libqico.a
$qt_plugins/imageformats/libqjpeg.a
$qt_plugins/imageformats/libqsvg.a

# Qt6 resource initialization objects
$qt_objects/QWasmIntegrationPlugin_resources_1/.qt/rcc/qrc_wasmfonts_init.cpp.o
$qt_objects/QWasmIntegrationPlugin_resources_2/.qt/rcc/qrc_wasmwindow_init.cpp.o
$qt_objects/Gui_resources_1/.qt/rcc/qrc_qpdf_init.cpp.o
$qt_objects/Gui_resources_2/.qt/rcc/qrc_gui_shaders_init.cpp.o
$qt_objects/Widgets_resources_1/.qt/rcc/qrc_qstyle_init.cpp.o
$qt_objects/Widgets_resources_2/.qt/rcc/qrc_qstyle1_init.cpp.o
$qt_objects/Widgets_resources_3/.qt/rcc/qrc_qstyle_fusion_init.cpp.o
$qt_objects/Widgets_resources_4/.qt/rcc/qrc_qmessagebox_init.cpp.o
LDFLAGS

    # Step 2: Patch Pyodide source (main.c + Makefile.envs)
    log "Patching Pyodide source..."
    python3 "$PATCHES_DIR/apply-wasm-patches.py" \
        --pyodide "$PYODIDE_REPO" \
        --build-dir "$BUILD_DIR"

    # Step 3: Compile Qt plugin import file and threading stubs
    log "Compiling Qt plugin imports and stubs..."
    local qt_include="$QT_INSTALL/include"
    em++ \
        -fPIC \
        -std=gnu++17 \
        -DQT_STATIC \
        -I"$qt_include" \
        -I"$qt_include/QtCore" \
        -I"$qt_include/QtGui" \
        -c "$PATCHES_DIR/qt_plugin_import.cpp" \
        -o "$BUILD_DIR/qt_plugin_import.o"
    emcc \
        -fPIC \
        -c "$PATCHES_DIR/qt_wasm_stubs.c" \
        -o "$BUILD_DIR/qt_wasm_stubs.o"

    # Step 4: Download emdawnwebgpu local port
    local dawn_version="v20260219.200501"
    if [ ! -d "$PYODIDE_REPO/emdawnwebgpu_pkg" ]; then
        log "Downloading emdawnwebgpu port..."
        pushd "$PYODIDE_REPO"
        wget -q "https://github.com/google/dawn/releases/download/${dawn_version}/emdawnwebgpu_pkg-${dawn_version}.zip"
        unzip -q "emdawnwebgpu_pkg-${dawn_version}.zip"
        rm -f "emdawnwebgpu_pkg-${dawn_version}.zip"
        popd
    fi

    # Step 5: Build Pyodide (CPython + link)
    log "Building Pyodide..."
    local pyversion
    pyversion=$(grep 'PYVERSION' "$PYODIDE_REPO/Makefile.envs" | head -1 | sed 's/.*?= *//')
    local pymajmin="${pyversion%.*}"
    local pyodide_lib="$PYODIDE_REPO/cpython/installs/python-${pyversion}/lib/python${pymajmin}"

    pushd "$PYODIDE_REPO"
    export PYODIDE_ROOT="$(pwd)"

    # Build CPython first so we can install the import hook
    make "$pyodide_lib"

    # Install the import hook before the stdlib gets zipped
    log "Installing PyQt6 import hook..."
    cp "$PATCHES_DIR/pyqt6_import_hook.py" "$pyodide_lib/pyqt6_import_hook.py"
    mkdir -p "$pyodide_lib/site-packages"
    local sitecustomize="$pyodide_lib/site-packages/sitecustomize.py"
    if ! grep -q "pyqt6_import_hook" "$sitecustomize" 2>/dev/null; then
        echo "import pyqt6_import_hook" >> "$sitecustomize"
    fi

    # Build everything else (link step picks up our patched MAIN_MODULE_LDFLAGS)
    make all-but-packages

    # Generate a minimal pyodide-lock.json (no packages — PyQt6 is built-in)
    if [ ! -f dist/pyodide-lock.json ]; then
        local em_ver
        em_ver=$(emcc --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
        local em_platform="emscripten_${em_ver//./_}"
        python3 -c "
import json, sys
lock = {
    'info': {
        'arch': 'wasm32',
        'platform': '${em_platform}',
        'version': '0.30.0-dev',
        'python': '${pyversion}',
        'abi_version': '2025_0',
    },
    'packages': {}
}
json.dump(lock, sys.stdout, indent=2)
print()
" > dist/pyodide-lock.json
    fi
    popd

    # Copy our test page into dist (with paths adjusted for flat layout)
    sed 's|./build/sources/pyodide/dist/|./|g' "$ROOT_DIR/test.html" > "$PYODIDE_REPO/dist/test.html"

    log "Build complete! Output in: $PYODIDE_REPO/dist/"
}

# ---- Package ----------------------------------------------------------------

do_package() {
    local dist_dir="$PYODIDE_REPO/dist"
    if [ ! -d "$dist_dir" ]; then
        err "No dist directory found at $dist_dir — run build first"
    fi

    local version
    version="$(grep '^version' "$ROOT_DIR/pixi.toml" | head -1 | sed 's/.*"\(.*\)".*/\1/')"
    local out_dir="$ROOT_DIR/dist"
    local zip_name="pyodide-qt-${version}.zip"

    mkdir -p "$out_dir"

    log "Packaging $zip_name..."

    # Create a staging directory with clean structure
    local staging="$BUILD_DIR/staging/pyodide-qt"
    rm -rf "$BUILD_DIR/staging"
    mkdir -p "$staging"

    # Copy Pyodide dist files
    cp "$dist_dir/pyodide.mjs" "$staging/"
    cp "$dist_dir/pyodide.asm.wasm" "$staging/"
    cp "$dist_dir/pyodide.asm.mjs" "$staging/"
    cp "$dist_dir/pyodide-lock.json" "$staging/"
    cp "$dist_dir/python_stdlib.zip" "$staging/"
    cp "$dist_dir/pyodide.js" "$staging/" 2>/dev/null || true
    cp "$dist_dir/package.json" "$staging/" 2>/dev/null || true

    # Copy test page with paths adjusted for flat layout
    sed 's|./build/sources/pyodide/dist/|./|g' "$ROOT_DIR/test.html" > "$staging/test.html"

    # Create the zip
    pushd "$BUILD_DIR/staging" >/dev/null
    zip -r "$out_dir/$zip_name" pyodide-qt/
    popd >/dev/null

    rm -rf "$BUILD_DIR/staging"

    local size
    size="$(du -h "$out_dir/$zip_name" | cut -f1)"
    log "Package created: dist/$zip_name ($size)"
}

# ---- Clean ------------------------------------------------------------------

do_clean() {
    log "Cleaning build artifacts..."
    rm -rf "$BUILD_DIR"
    log "Clean complete"
}

# ---- Main -------------------------------------------------------------------

case "${1:-all}" in
    qt)       build_qt ;;
    pyqt)     build_pyqt ;;
    pyodide)  build_pyodide ;;
    package)  do_package ;;
    clean)    do_clean ;;
    all)
        download_sources
        build_qt
        build_pyqt
        build_pyodide
        log "Build complete!"
        ;;
    *)
        echo "Usage: $0 {all|qt|pyqt|pyodide|package|clean}"
        exit 1
        ;;
esac
