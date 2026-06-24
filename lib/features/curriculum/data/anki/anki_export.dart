// Facade for in-app Anki export. Resolves to the native implementation
// (dart:io + sqlite3) everywhere except web, which gets a throwing stub —
// so the app still compiles for the web target. Callers guard on
// [ankiExportSupported] before invoking [exportApkgToTemp].
export 'anki_export_io.dart' if (dart.library.html) 'anki_export_unsupported.dart';
