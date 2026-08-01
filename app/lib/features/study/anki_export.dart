/// Facade for in-app Anki export (donor Trellis pattern, kept): native
/// platforms get the real pure-Dart `.apkg` builder; web gets a throwing
/// stub so the app still compiles there. Callers guard the button on
/// [ankiExportSupported] instead of ever catching the stub's throw.
library;

export 'anki_export_io.dart'
    if (dart.library.js_interop) 'anki_export_unsupported.dart';
