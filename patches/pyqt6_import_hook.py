# PyQt6 import hook for Pyodide.
# When PyQt6 modules are registered as built-in modules via PyImport_AppendInittab,
# Python's import system needs help resolving "PyQt6.QtCore" etc. because the
# parent package "PyQt6" is a built-in (not a filesystem package).
# This hook makes built-in modules discoverable as sub-modules.

from importlib import abc, machinery
import sys


class PyQt6Finder(abc.MetaPathFinder):
    """MetaPathFinder that resolves PyQt6.* built-in modules."""

    _MODULES = frozenset(sys.builtin_module_names) & {
        "PyQt6", "PyQt6.sip",
        "PyQt6.QtCore", "PyQt6.QtGui", "PyQt6.QtWidgets",
        "PyQt6.QtSvg", "PyQt6.QtSvgWidgets", "PyQt6.QtXml",
    }

    def find_spec(self, fullname, path, target=None):
        if fullname in self._MODULES:
            return machinery.ModuleSpec(fullname, machinery.BuiltinImporter)
        return None


sys.meta_path.insert(0, PyQt6Finder())
