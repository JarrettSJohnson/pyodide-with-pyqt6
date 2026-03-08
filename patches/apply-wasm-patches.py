#!/usr/bin/env python3
"""Apply WASM-specific patches to PyQt6 SIP files.

These patches add feature guards for Qt features that are disabled in WASM builds:
- timezone (QT_CONFIG(timezone) is disabled)
- systemsemaphore (QT_NO_SYSTEMSEMAPHORE is defined)
- process (QT_NO_PROCESS is defined) — already has PyQt_Process guard, but
  QProcessEnvironment operators outside the guard need fixing
"""

import re
import sys
from pathlib import Path


def patch_file(path: Path, patches: list[tuple[str, str]]):
    """Apply string replacements to a file."""
    text = path.read_text()
    for old, new in patches:
        if new in text:
            continue  # already patched
        if old not in text:
            print(f"  WARNING: pattern not found in {path.name}: {old[:60]}...")
            continue
        text = text.replace(old, new)
    path.write_text(text)
    print(f"  Patched {path.name}")


def patch_pyqt6(src_dir: Path):
    """Apply all WASM patches to PyQt6 source."""
    sip_dir = src_dir / "sip" / "QtCore"

    # 1. Add new feature declarations to QtCoremod.sip
    print("Adding feature declarations...")
    patch_file(sip_dir / "QtCoremod.sip", [
        # Add new features after PyQt_SessionManager
        ("%Feature PyQt_SessionManager\n",
         "%Feature PyQt_SessionManager\n%Feature PyQt_Timezone\n%Feature PyQt_SystemSemaphore\n%Feature PyQt_Thread\n"),

        # Wrap threading-related includes (disabled with -no-feature-thread)
        ("%Include qreadwritelock.sip\n",
         "%If (PyQt_Thread)\n%Include qreadwritelock.sip\n%End\n"),
        ("%Include qmutex.sip\n",
         "%If (PyQt_Thread)\n%Include qmutex.sip\n%End\n"),
        ("%Include qmutexlocker.sip\n",
         "%If (PyQt_Thread)\n%Include qmutexlocker.sip\n%End\n"),
        ("%Include qthread.sip\n",
         "%If (PyQt_Thread)\n%Include qthread.sip\n%End\n"),
        ("%Include qthreadpool.sip\n",
         "%If (PyQt_Thread)\n%Include qthreadpool.sip\n%End\n"),
        ("%Include qsemaphore.sip\n",
         "%If (PyQt_Thread)\n%Include qsemaphore.sip\n%End\n"),
        ("%Include qwaitcondition.sip\n",
         "%If (PyQt_Thread)\n%Include qwaitcondition.sip\n%End\n"),
        ("%Include qrunnable.sip\n",
         "%If (PyQt_Thread)\n%Include qrunnable.sip\n%End\n"),

        # Wrap %Include directives for disabled modules
        ("%Include qsystemsemaphore.sip\n",
         "%If (PyQt_SystemSemaphore)\n%Include qsystemsemaphore.sip\n%End\n"),

        ("%Include qsharedmemory.sip\n",
         "%If (PyQt_SystemSemaphore)\n%Include qsharedmemory.sip\n%End\n"),

        # For full timezone support, include the original file; otherwise
        # include a minimal stub with just the always-available API
        ("%Include qtimezone.sip\n",
         "%If (PyQt_Timezone)\n%Include qtimezone.sip\n%End\n"
         "%If (!PyQt_Timezone)\n%Include qtimezone_stub.sip\n%End\n"),
    ])

    # 2. Copy timezone stub SIP file
    import shutil
    stub_src = Path(__file__).parent / "qtimezone_stub.sip"
    if stub_src.exists():
        shutil.copy2(stub_src, sip_dir / "qtimezone_stub.sip")
        print("  Copied qtimezone_stub.sip")

    # 3. Wrap timezone-dependent parts of qtimezone.sip (for reference/non-WASM)
    # Strategy: wrap every line that references TimeType, NameType, OffsetData,
    # OffsetDataList, or any timezone-backend method in %If (PyQt_Timezone)
    print("Patching qtimezone.sip...")
    tz_sip = sip_dir / "qtimezone.sip"
    text = tz_sip.read_text()
    lines = text.split("\n")
    result = []
    in_guard = False
    # Track multi-line constructs like struct and enum
    tz_keywords = {"TimeType", "NameType", "OffsetData", "OffsetDataList",
                   "displayName", "abbreviation", "offsetFromUtc",
                   "standardTimeOffset", "daylightTimeOffset",
                   "hasDaylightTime", "isDaylightTime", "hasTransitions",
                   "nextTransition", "previousTransition", "transitions",
                   "systemTimeZoneId", "availableTimeZoneIds",
                   "ianaIdToWindowsId", "windowsIdToDefaultIanaId",
                   "windowsIdToIanaIds", "asBackendZone", "hasAlternativeName"}

    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        # Skip lines already inside %If (PyQt_Timezone)
        if stripped == "%If (PyQt_Timezone)":
            result.append(line)
            i += 1
            # Copy until matching %End
            depth = 1
            while i < len(lines) and depth > 0:
                if lines[i].strip().startswith("%If"):
                    depth += 1
                elif lines[i].strip() == "%End":
                    depth -= 1
                result.append(lines[i])
                i += 1
            continue

        # Check if this line needs timezone guarding
        needs_guard = False
        if stripped and not stripped.startswith("//") and not stripped.startswith("%"):
            for kw in tz_keywords:
                if kw in stripped:
                    needs_guard = True
                    break

        if needs_guard:
            result.append("%If (PyQt_Timezone)")
            # Handle multi-line constructs (enum, struct)
            if stripped.startswith("enum ") or stripped.startswith("struct "):
                result.append(line)
                i += 1
                while i < len(lines) and not lines[i].strip().startswith("};"):
                    result.append(lines[i])
                    i += 1
                if i < len(lines):
                    result.append(lines[i])  # the };
                    i += 1
            else:
                result.append(line)
                i += 1
            result.append("%End")
        else:
            result.append(line)
            i += 1

    tz_sip.write_text("\n".join(result))
    print(f"  Patched qtimezone.sip")

    # 3. Wrap QTimeZone-using methods in qdatetime.sip
    print("Patching qdatetime.sip...")
    dt_sip = sip_dir / "qdatetime.sip"
    dt_text = dt_sip.read_text()
    dt_replacements = []

    # Find all lines referencing QTimeZone (but not QTimeZone::Initialization which is always available)
    for line in dt_text.split("\n"):
        stripped = line.strip()
        if "QTimeZone" in stripped and "Initialization" not in stripped and not stripped.startswith("//"):
            # This is a method using QTimeZone timezone features
            full_line = line + "\n"
            if full_line in dt_text and f"%If (PyQt_Timezone)\n{full_line}" not in dt_text:
                # Check if it's a multi-line declaration by looking for ;
                if ";" in line:
                    dt_replacements.append((full_line, f"%If (PyQt_Timezone)\n{full_line}%End\n"))

    for old, new in dt_replacements:
        dt_text = dt_text.replace(old, new)
    dt_sip.write_text(dt_text)
    print(f"  Patched qdatetime.sip")

    # 4. Wrap QTimeZone-using methods in qfileinfo.sip
    print("Patching qfileinfo.sip...")
    fi_sip = sip_dir / "qfileinfo.sip"
    if fi_sip.exists():
        fi_text = fi_sip.read_text()
        fi_replacements = []
        for line in fi_text.split("\n"):
            stripped = line.strip()
            if "QTimeZone" in stripped and not stripped.startswith("//"):
                full_line = line + "\n"
                if ";" in line and f"%If (PyQt_Timezone)\n{full_line}" not in fi_text:
                    fi_replacements.append((full_line, f"%If (PyQt_Timezone)\n{full_line}%End\n"))
        for old, new in fi_replacements:
            fi_text = fi_text.replace(old, new)
        fi_sip.write_text(fi_text)
        print(f"  Patched qfileinfo.sip")

    # 5. Fix QProcessEnvironment operators outside %If (PyQt_Process) guard
    print("Patching qprocess.sip...")
    qp_sip = sip_dir / "qprocess.sip"
    if qp_sip.exists():
        qp_text = qp_sip.read_text()
        old_block = """%End
%If (Qt_6_8_0 -)
bool operator!=(const QProcessEnvironment &lhs, const QProcessEnvironment &rhs);
%End
%If (Qt_6_8_0 -)
bool operator==(const QProcessEnvironment &lhs, const QProcessEnvironment &rhs);
%End"""
        new_block = """%End
%If (PyQt_Process)
%If (Qt_6_8_0 -)
bool operator!=(const QProcessEnvironment &lhs, const QProcessEnvironment &rhs);
%End
%If (Qt_6_8_0 -)
bool operator==(const QProcessEnvironment &lhs, const QProcessEnvironment &rhs);
%End
%End"""
        if old_block in qp_text and "%If (PyQt_Process)\n%If (Qt_6_8_0" not in qp_text:
            qp_text = qp_text.replace(old_block, new_block)
            qp_sip.write_text(qp_text)
            print(f"  Patched qprocess.sip")
        else:
            print(f"  qprocess.sip already patched or pattern not found")

    # 6. Patch QSharedMemory and QThread references in qobject.sip
    print("Patching qobject.sip...")
    qo_sip = sip_dir / "qobject.sip"
    if qo_sip.exists():
        qo_text = qo_sip.read_text()
        if "sipName_QSharedMemory" in qo_text:
            qo_text = qo_text.replace(
                "        {sipName_QSharedMemory, &sipType_QSharedMemory, -1, 16},",
                "#if !defined(QT_NO_SYSTEMSEMAPHORE)\n"
                "        {sipName_QSharedMemory, &sipType_QSharedMemory, -1, 16},\n"
                "#else\n"
                "        {0, 0, -1, 16},\n"
                "#endif"
            )

        # Guard QThread/QThreadPool type hierarchy entries
        if "sipName_QThread" in qo_text and "#if !defined(QT_NO_THREAD)" not in qo_text:
            qo_text = qo_text.replace(
                "        {sipName_QThread, &sipType_QThread, -1, 19},\n"
                "        {sipName_QThreadPool, &sipType_QThreadPool, -1, 20},",
                "#if QT_CONFIG(thread)\n"
                "        {sipName_QThread, &sipType_QThread, -1, 19},\n"
                "        {sipName_QThreadPool, &sipType_QThreadPool, -1, 20},\n"
                "#else\n"
                "        {0, 0, -1, 19},\n"
                "        {0, 0, -1, 20},\n"
                "#endif"
            )

        # Guard thread()/moveToThread() methods
        if "QThread *thread() const;" in qo_text and "%If (PyQt_Thread)" not in qo_text:
            qo_text = qo_text.replace(
                "    QThread *thread() const;\n"
                "    void moveToThread(QThread *thread);",
                "%If (PyQt_Thread)\n"
                "    QThread *thread() const;\n"
                "    void moveToThread(QThread *thread);\n"
                "%End"
            )

        qo_sip.write_text(qo_text)
        print(f"  Patched qobject.sip")

    # 7. Guard QThread references in other SIP files (for -no-feature-thread builds)
    print("Patching qabstracteventdispatcher.sip...")
    aed_sip = sip_dir / "qabstracteventdispatcher.sip"
    if aed_sip.exists():
        patch_file(aed_sip, [
            ("    static QAbstractEventDispatcher *instance(QThread *thread = 0);",
             "%If (PyQt_Thread)\n    static QAbstractEventDispatcher *instance(QThread *thread = 0);\n%End\n%If (!PyQt_Thread)\n    static QAbstractEventDispatcher *instance();\n%End"),
        ])

    print("Patching qeventloop.sip...")
    el_sip = sip_dir / "qeventloop.sip"
    if el_sip.exists():
        patch_file(el_sip, [
            ("    explicit QEventLoopLocker(QThread *thread) /ReleaseGIL/;",
             "%If (PyQt_Thread)\n    explicit QEventLoopLocker(QThread *thread) /ReleaseGIL/;\n%End"),
        ])

    print("Patching qcoreapplication.sip...")
    qca_sip = sip_dir / "qcoreapplication.sip"
    if qca_sip.exists():
        patch_file(qca_sip, [
            ("    if (app && app->thread() == QThread::currentThread())",
             "#if QT_CONFIG(thread)\n    if (app && app->thread() == QThread::currentThread())\n#else\n    if (app)\n#endif"),
        ])

    # 8. Guard QThread/QMutex references in qpy C++ source files
    print("Patching qpy/QtCore C++ files for no-thread builds...")
    qpy_dir = src_dir / "qpy" / "QtCore"

    # qpycore_public_api.cpp: guard QThread include and usage
    pub_api = qpy_dir / "qpycore_public_api.cpp"
    if pub_api.exists():
        patch_file(pub_api, [
            ("#include <QThread>",
             "#if QT_CONFIG(thread)\n#include <QThread>\n#endif"),
            ("    // Ignore running threads.\n"
             "    if (PyObject_TypeCheck((PyObject *)sw, sipTypeAsPyTypeObject(sipType_QThread)))\n"
             "    {\n"
             "        QThread *thr = reinterpret_cast<QThread *>(addr);\n"
             "\n"
             "        if (thr->isRunning())\n"
             "            return;\n"
             "    }",
             "#if QT_CONFIG(thread)\n"
             "    // Ignore running threads.\n"
             "    if (PyObject_TypeCheck((PyObject *)sw, sipTypeAsPyTypeObject(sipType_QThread)))\n"
             "    {\n"
             "        QThread *thr = reinterpret_cast<QThread *>(addr);\n"
             "\n"
             "        if (thr->isRunning())\n"
             "            return;\n"
             "    }\n"
             "#endif"),
        ])

    # qpycore_pyqtmutexlocker.cpp: wrap entire file in #if QT_CONFIG(thread)
    mutex_cpp = qpy_dir / "qpycore_pyqtmutexlocker.cpp"
    if mutex_cpp.exists():
        text = mutex_cpp.read_text()
        if "#if QT_CONFIG(thread)" not in text:
            mutex_cpp.write_text("#include <QtCore/qtconfigmacros.h>\n#include <QtCore/qtcore-config.h>\n#if QT_CONFIG(thread)\n" + text + "\n#endif\n")
            print(f"  Wrapped qpycore_pyqtmutexlocker.cpp in thread guard")

    # qpycore_pyqtmutexlocker.h: wrap entire file in #if QT_CONFIG(thread)
    mutex_h = qpy_dir / "qpycore_pyqtmutexlocker.h"
    if mutex_h.exists():
        text = mutex_h.read_text()
        if "#if QT_CONFIG(thread)" not in text:
            mutex_h.write_text("#include <QtCore/qtconfigmacros.h>\n#include <QtCore/qtcore-config.h>\n#if QT_CONFIG(thread)\n" + text + "\n#endif\n")
            print(f"  Wrapped qpycore_pyqtmutexlocker.h in thread guard")

    print("All patches applied.")


def patch_pyqtbuild(bindings_py: Path):
    """Patch pyqtbuild's bindings.py to support PYQT_WASM_FEATURES env var."""
    text = bindings_py.read_text()
    if "PYQT_WASM_FEATURES" in text:
        print("  pyqtbuild/bindings.py already patched")
        return

    old = '''    def is_buildable(self):
        """ Return True of the bindings are buildable. """

        project = self.project'''

    new = '''    def is_buildable(self):
        """ Return True of the bindings are buildable. """

        # WASM cross-compilation: skip config tests entirely and use
        # hardcoded disabled features from PYQT_WASM_FEATURES env var.
        # Format: "Module1=feat1,feat2;Module2=feat3"
        wasm_features = os.environ.get('PYQT_WASM_FEATURES')
        if wasm_features is not None:
            self.project.progress(
                    "WASM cross-build: skipping config test for {0}".format(
                            self.name))
            features_map = {}
            for entry in wasm_features.split(';'):
                if '=' in entry:
                    mod, feats = entry.split('=', 1)
                    features_map[mod] = feats.split(',') if feats else []
            test_output = features_map.get(self.name, [])
            return self.handle_test_output(test_output)

        project = self.project'''

    if old in text:
        text = text.replace(old, new)
        bindings_py.write_text(text)
        print("  Patched pyqtbuild/bindings.py")
    else:
        print("  WARNING: Could not find patch target in bindings.py")


def patch_pyodide(pyodide_dir: Path, build_dir: Path):
    """Patch Pyodide source to register PyQt6 built-in modules and link Qt6 libs.

    Patches:
    - src/core/main.c: register PyQt6 modules via PyImport_AppendInittab
    - Makefile.envs: append Qt6/PyQt6 static libraries to MAIN_MODULE_LDFLAGS
    """

    # --- Patch main.c ---
    main_c = pyodide_dir / "src" / "core" / "main.c"
    if not main_c.exists():
        print(f"ERROR: {main_c} not found")
        sys.exit(1)

    text = main_c.read_text()
    if "PyQt6" not in text:
        decls = """\
/* PyQt6 static module init functions */
extern PyObject *PyInit_QtCore();
extern PyObject *PyInit_QtGui();
extern PyObject *PyInit_QtWidgets();
extern PyObject *PyInit_QtSvg();
extern PyObject *PyInit_QtSvgWidgets();
extern PyObject *PyInit_QtXml();
extern PyObject *PyInit_sip();

/* Create a namespace package for PyQt6 */
static struct PyModuleDef pyqt6_module_def = {
    PyModuleDef_HEAD_INIT,
    "PyQt6",
    NULL,
    -1,
    NULL
};

static PyObject *PyInit_PyQt6(void) {
    PyObject *mod = PyModule_Create(&pyqt6_module_def);
    if (mod == NULL) return NULL;
    /* Set __path__ to make it a package */
    PyObject *path = PyList_New(0);
    if (path == NULL) { Py_DECREF(mod); return NULL; }
    PyObject_SetAttrString(mod, "__path__", path);
    Py_DECREF(path);
    /* Set __file__ so QtCore can find qt.conf location */
    PyModule_AddStringConstant(mod, "__file__", "/lib/python3.13/PyQt6/__init__.py");
    return mod;
}

static void register_pyqt6_modules(void) {
    PyImport_AppendInittab("PyQt6", PyInit_PyQt6);
    PyImport_AppendInittab("PyQt6.sip", PyInit_sip);
    PyImport_AppendInittab("PyQt6.QtCore", PyInit_QtCore);
    PyImport_AppendInittab("PyQt6.QtGui", PyInit_QtGui);
    PyImport_AppendInittab("PyQt6.QtWidgets", PyInit_QtWidgets);
    PyImport_AppendInittab("PyQt6.QtSvg", PyInit_QtSvg);
    PyImport_AppendInittab("PyQt6.QtSvgWidgets", PyInit_QtSvgWidgets);
    PyImport_AppendInittab("PyQt6.QtXml", PyInit_QtXml);
}

"""
        text = text.replace(
            '#define FAIL_IF_STATUS_EXCEPTION',
            decls + '#define FAIL_IF_STATUS_EXCEPTION'
        )
        text = text.replace(
            'PyImport_AppendInittab("_pyodide_core", PyInit__pyodide_core);',
            'PyImport_AppendInittab("_pyodide_core", PyInit__pyodide_core);\n  register_pyqt6_modules();'
        )
        main_c.write_text(text)
        print("  Patched main.c")
    else:
        print("  main.c already patched")

    # --- Patch Makefile.envs ---
    makefile_envs = pyodide_dir / "Makefile.envs"
    text = makefile_envs.read_text()
    if "pyqt6-ldflags" not in text:
        ldflags_path = build_dir / "pyqt6-ldflags.txt"
        # Append Qt6/PyQt6 libraries to MAIN_MODULE_LDFLAGS
        # Find the end of the first MAIN_MODULE_LDFLAGS block (the line before
        # the blank line + EXPORTS=). We append our libs there.
        shell_cmd = (
            f"$(shell grep -v '^\\#' {ldflags_path} 2>/dev/null "
            "| grep -v '^$$' | tr '\\n' ' ')"
        )

        # Find the first MAIN_MODULE_LDFLAGS block's last line
        # It ends with a line that does NOT end with backslash, followed by blank + EXPORTS
        lines = text.split('\n')
        insert_idx = None
        in_main_ldflags = False
        for i, line in enumerate(lines):
            if 'export MAIN_MODULE_LDFLAGS=' in line:
                in_main_ldflags = True
            if in_main_ldflags and not line.rstrip().endswith('\\') and line.strip():
                # This is the last line of the block
                insert_idx = i
                in_main_ldflags = False
                break

        if insert_idx is not None:
            last_line = lines[insert_idx]
            # Add continuation backslash to current last line, then our additions
            emdawn_port = pyodide_dir / "emdawnwebgpu_pkg" / "emdawnwebgpu.port.py"
            lines[insert_idx] = last_line + ' \\'
            lines.insert(insert_idx + 1, f'\t--use-port={emdawn_port} \\')
            lines.insert(insert_idx + 2, '\t-lembind \\')
            lines.insert(insert_idx + 3, '\t\\')
            lines.insert(insert_idx + 4, f'\t{shell_cmd}')
            makefile_envs.write_text('\n'.join(lines))
            print("  Patched Makefile.envs")
        else:
            print("  WARNING: Could not find MAIN_MODULE_LDFLAGS in Makefile.envs")
    else:
        print("  Makefile.envs already patched")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <pyqt6-source-dir> [pyqtbuild-bindings.py] [--pyodide <dir> --build-dir <dir>]")
        sys.exit(1)

    # Parse --pyodide and --build-dir flags
    args = sys.argv[1:]
    pyodide_dir = None
    build_dir_arg = None
    positional = []
    i = 0
    while i < len(args):
        if args[i] == "--pyodide" and i + 1 < len(args):
            pyodide_dir = Path(args[i + 1])
            i += 2
        elif args[i] == "--build-dir" and i + 1 < len(args):
            build_dir_arg = Path(args[i + 1])
            i += 2
        else:
            positional.append(args[i])
            i += 1

    if positional:
        src = Path(positional[0])
        if not (src / "sip" / "QtCore" / "QtCoremod.sip").exists():
            print(f"ERROR: {src} doesn't look like a PyQt6 source directory")
            sys.exit(1)
        patch_pyqt6(src)

    if len(positional) > 1:
        patch_pyqtbuild(Path(positional[1]))

    if pyodide_dir and build_dir_arg:
        patch_pyodide(pyodide_dir, build_dir_arg)
