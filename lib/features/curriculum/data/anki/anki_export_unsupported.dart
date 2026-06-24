// Web / unsupported fallback: building a real Anki .apkg needs dart:io +
// sqlite3, which aren't available on the web target. The button is hidden when
// [ankiExportSupported] is false, so these throw only if called directly.
import 'dart:typed_data';

import '../../domain/models.dart';

bool get ankiExportSupported => false;

Uint8List buildApkgBytes(Course course) =>
    throw UnsupportedError('Anki .apkg export requires a native platform.');

Future<String> exportApkgToTemp(Course course) =>
    throw UnsupportedError('Anki .apkg export is unavailable on web.');
