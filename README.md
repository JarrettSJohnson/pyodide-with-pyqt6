# PyQt6 on Pyodide

Run PyQt6 widgets in the browser via [Pyodide](https://pyodide.org/) and Qt6's WebAssembly support.

![PyQt6 running in the browser](https://img.shields.io/badge/status-proof%20of%20concept-yellow)

## What this is

A build system that compiles Qt6 + PyQt6 to WebAssembly and links them into Pyodide, allowing Python GUI code like this to run in a browser:

```python
from PyQt6.QtWidgets import QApplication, QLabel
app = QApplication([])
label = QLabel("Hello from PyQt6!")
label.show()
```

Qt renders to a `<div>` container element via Emscripten's HTML5 canvas backend.

## Prerequisites

- [pixi](https://pixi.sh/) (package manager)
- ~10 GB disk space (Qt6 source + build artifacts)
- macOS or Linux (tested on macOS arm64)

## Quick start

```bash
pixi run build       # full build (~45 min first time)
pixi run serve       # serve on localhost:8080
# open http://localhost:8080/test.html
```

### Individual build phases

```bash
pixi run build-qt      # Phase 1: Qt6 for WASM (~30 min)
pixi run build-pyqt    # Phase 2: SIP + PyQt6 modules (~5 min)
pixi run build-pyodide # Phase 3: Link into Pyodide (~2 min)
pixi run clean         # Remove all build artifacts
```

## How it works

```
┌─────────────────────────────────────────────────────┐
│ Browser                                             │
│  ┌───────────────┐  ┌────────────────────────────┐  │
│  │ Pyodide (JS)  │──│ Python 3.13 (WASM)         │  │
│  │               │  │  ├─ PyQt6.QtCore            │  │
│  │               │  │  ├─ PyQt6.QtGui             │  │
│  │               │  │  ├─ PyQt6.QtWidgets         │  │
│  │               │  │  └─ ...                     │  │
│  └───────────────┘  └─────────┬──────────────────┘  │
│                               │                     │
│  ┌────────────────────────────▼──────────────────┐  │
│  │ Qt6 (WASM) ──► <div> container ──► Canvas     │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

1. **Qt6** is compiled from source to WebAssembly using Emscripten
2. **PyQt6** (SIP-generated C++ bindings) is compiled against the WASM Qt6
3. Everything is **statically linked** into a single Pyodide WASM binary
4. Python modules are registered via `PyImport_AppendInittab` as builtins

All WASM compilation uses **Pyodide's own Emscripten SDK** to ensure ABI compatibility (wasm exceptions, PIC relocations, longjmp mode).

## Browser usage

```html
<div id="qt-container" style="width: 800px; height: 600px;"></div>
<script type="module">
  import { loadPyodide } from "./pyodide/pyodide.mjs";
  const pyodide = await loadPyodide();
  pyodide._module.qtContainerElements = [document.getElementById("qt-container")];
  pyodide.runPython(`
    from PyQt6.QtWidgets import QApplication, QLabel
    app = QApplication([])
    label = QLabel("Hello World!")
    label.show()
  `);
</script>
```

Key points:
- Set `qtContainerElements` on the Pyodide module **before** creating `QApplication`
- Qt renders into the container `<div>` elements
- Don't call `app.exec()` — the browser event loop drives Qt

## Available modules

| Module | Status |
|--------|--------|
| QtCore | Working |
| QtGui | Working |
| QtWidgets | Working |
| QtSvg | Working |
| QtSvgWidgets | Working |
| QtXml | Working |
| sip | Working |

Threading classes (QThread, QMutex, etc.) are excluded — WASM is single-threaded.

## Version matrix

| Component | Version |
|-----------|---------|
| Qt6 | 6.10.2 |
| PyQt6 | 6.10.2 |
| Pyodide | main (0.30.0-dev) |
| Python | 3.13.2 |
| Emscripten | 4.0.9 |

## Project structure

```
├── build.sh                      # Build pipeline (qt → pyqt → pyodide)
├── pixi.toml                     # Host tool dependencies
├── test.html                     # Browser test page
├── patches/
│   ├── apply-wasm-patches.py     # WASM patches for PyQt6 + Pyodide
│   ├── qt_plugin_import.cpp      # Qt static plugin registration
│   ├── qt_wasm_stubs.c           # No-op stubs for pthread/idb functions
│   ├── qtimezone_stub.sip        # Minimal QTimeZone for non-timezone builds
│   └── pyqt6_import_hook.py      # PyQt6 namespace import hook
└── build/                        # Build artifacts (gitignored)
    ├── qt6-wasm/                 # Qt6 WASM install
    ├── pyqt6-build/              # PyQt6 module .a libraries
    ├── pyqt6-sip-build/          # PyQt6-sip .a library
    └── sources/                  # Cloned sources (Qt6, Pyodide, PyQt6)
```

## Known limitations

- **No `app.exec()`** — the browser event loop must drive Qt; blocking calls will freeze the page
- **No threads** — Qt is built with `-no-feature-thread`; QThread/QMutex APIs unavailable
- **Single window** — Qt WASM renders to container elements; multi-window requires multiple containers
- **Large binary** — the WASM output is ~33 MB (could be reduced with `-Oz` and dead code stripping)
- **GPL v3** — PyQt6 is GPL-licensed

## Acknowledgments

- [pyodide-with-pyqt5](https://github.com/viur-framework/pyodide-with-pyqt5) by viur-framework — proved this approach works
- [pyodide-recipes#183](https://github.com/pyodide/pyodide-recipes/issues/183) — the issue that inspired this project

## License

Build scripts and patches are MIT. PyQt6 itself is GPL v3.
