import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../../services/picked_save.dart';

/// The backup screen's only door to the filesystem. A seam, not a
/// convenience: widget tests hand the screen a fake and never touch the
/// real picker (platform channels stay behind seams), and every byte that
/// leaves or enters the backup flow is visible at this one interface.
///
/// Nothing here touches the network — backups are files the user places by
/// hand, which is why this whole feature lives outside the consent
/// chokepoint (ADR-0003 law 6 governs egress; a local file is not egress).
abstract class BackupGateway {
  /// Offers [bytes] under [suggestedName]; false when the user declined.
  Future<bool> saveBytes(String suggestedName, Uint8List bytes);

  /// One picked file's bytes (a `.ohbk`), or null when dismissed.
  Future<Uint8List?> pickBytes();

  /// One picked file's text (the donor's `.json` export), or null.
  Future<String?> pickText();
}

/// The real gateway over file_picker (the course-import precedent).
class FilePickerBackupGateway implements BackupGateway {
  @override
  Future<bool> saveBytes(String suggestedName, Uint8List bytes) async {
    final path = await FilePicker.platform
        .saveFile(fileName: suggestedName, type: FileType.any, bytes: bytes);
    return finishPickedSave(path, bytes);
  }

  @override
  Future<Uint8List?> pickBytes() async {
    final result = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['ohbk'], withData: true);
    final file = result?.files.firstOrNull;
    if (file == null) return null;
    return file.bytes ?? await File(file.path!).readAsBytes();
  }

  @override
  Future<String?> pickText() async {
    final result = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['json'], withData: true);
    final file = result?.files.firstOrNull;
    if (file == null) return null;
    final bytes = file.bytes ?? await File(file.path!).readAsBytes();
    return utf8.decode(bytes, allowMalformed: true);
  }
}
