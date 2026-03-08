// Smoke test: verify Pyodide loads and PyQt6 modules are importable
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const distDir = resolve(process.argv[2] || "./build/sources/pyodide/dist/") + "/";
const { loadPyodide } = await import(pathToFileURL(distDir + "pyodide.mjs").href);
const py = await loadPyodide({ indexURL: distDir });

// Note: QApplication and widgets require a browser environment (navigator, DOM).
// In Node.js we can only verify that the modules import successfully.
const results = py.runPython(`
results = []

from PyQt6 import QtCore
results.append("QtCore OK")

from PyQt6 import QtGui
results.append("QtGui OK")

from PyQt6 import QtWidgets
results.append("QtWidgets OK")

from PyQt6 import QtSvg
results.append("QtSvg OK")

"\\n".join(results)
`);

console.log(results);

const expected = ["QtCore OK", "QtGui OK", "QtWidgets OK", "QtSvg OK"];
for (const check of expected) {
  if (!results.includes(check)) {
    console.error(`FAIL: missing "${check}"`);
    process.exit(1);
  }
}

console.log("All smoke tests passed!");
