/// Web stub of the Anki exporter. The real builder needs a native sqlite
/// (dart:ffi), which the web target does not have; the UI hides the export
/// affordance behind [ankiExportSupported] so this throw is unreachable in
/// practice — it exists to keep the web build compiling, not to be caught.
library;

import 'dart:typed_data';

import 'package:study_core/study_core.dart';

bool get ankiExportSupported => false;

Future<Uint8List> buildApkgBytes(Course course) async =>
    throw UnsupportedError('Anki export is not available on the web');

String apkgFileName(Course course) =>
    throw UnsupportedError('Anki export is not available on the web');
