import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

/// Finishes a `FilePicker.saveFile(bytes: …)` call — the one save-finish
/// dance behind every "save a file" affordance (backup .ohbk, OPML
/// export). The picker's contract differs per platform: mobile pickers
/// write the bytes themselves, desktop ones only return a path, and on
/// the web a returned name means the browser download already happened —
/// any dart:io call after it throws under dart2js.
Future<bool> finishPickedSave(String? path, List<int> bytes,
    {bool isWeb = kIsWeb}) async {
  if (path == null) return false;
  if (isWeb) return true;
  final file = File(path);
  if (!await file.exists() || await file.length() == 0) {
    await file.writeAsBytes(bytes);
  }
  return true;
}
