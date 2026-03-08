// Static Qt plugin imports for WASM build.
// This file must be compiled and linked into the final Pyodide binary
// so that Qt can find its platform and image format plugins.

#include <QtPlugin>

Q_IMPORT_PLUGIN(QWasmIntegrationPlugin)
Q_IMPORT_PLUGIN(QGifPlugin)
Q_IMPORT_PLUGIN(QICOPlugin)
Q_IMPORT_PLUGIN(QJpegPlugin)
Q_IMPORT_PLUGIN(QSvgPlugin)
Q_IMPORT_PLUGIN(QSvgIconPlugin)
