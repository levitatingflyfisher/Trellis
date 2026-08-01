/// The audiobook import door's only touch of a platform picker (ADR-0013,
/// Campaign 7) — the same abstraction shape as `backup_gateway.dart`'s
/// [BackupGateway]: widget tests hand the screen a fake and never reach a
/// real platform channel.
library;

import 'package:file_picker/file_picker.dart';

/// One picked audio file — [name] is the original filename (chapter
/// parsing and playback both key off its extension); [path] is wherever
/// the platform actually put readable bytes, which on Android is a
/// short-lived cache copy the import step must read NOW, not later (see
/// ADR-0013's referenced-vs-copied verdict).
typedef PickedAudioFile = ({String path, String name});

const audiobookExtensions = ['mp3', 'm4a', 'm4b', 'ogg', 'opus', 'flac'];

/// Picks one or more audio files. Null means the picker was dismissed
/// with nothing chosen. A user navigating into an album folder and
/// selecting every track IS this app's folder import (ADR-0013 explains
/// why a separate directory-tree picker isn't offered on Android).
abstract class AudiobookPickerGateway {
  Future<List<PickedAudioFile>?> pickFiles();
}

class FilePickerAudiobookGateway implements AudiobookPickerGateway {
  @override
  Future<List<PickedAudioFile>?> pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: audiobookExtensions,
      allowMultiple: true,
    );
    final files = result?.files;
    if (files == null || files.isEmpty) return null;
    return [
      for (final f in files)
        if (f.path != null) (path: f.path!, name: f.name),
    ];
  }
}
