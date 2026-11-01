import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The web build has no transcription, translation or voice, so the
/// one-tap feature can never run there. It was compiled into the web
/// bundle anyway, with the ffmpeg bindings it pulls in: about 38 KB of
/// code no browser could reach (measured, 1.6.1). The app now reaches the
/// feature through one door that hands the web a stand-in. A stand-in
/// that drifts from the real thing breaks only the web build, which no
/// test compiles, so this checks the two by name.
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('the app reaches the feature only through its one door', () {
    for (final user in [
      'lib/features/works/work_page.dart',
      'lib/features/episodes/episode_actions.dart',
    ]) {
      final text = read(user);
      expect(text, contains("listen/listen.dart'"), reason: user);
      for (final direct in [
        'listen_chain.dart',
        'listen_device.dart',
        'listen_in_language_bar.dart',
        'spoken_episode.dart',
      ]) {
        expect(text, isNot(contains(direct)), reason: '$user imports $direct');
      }
    }
  });

  test('the door hands the web the stand-in, and everything else the real '
      'feature', () {
    final door = read('lib/features/listen/listen.dart');
    expect(door, contains("export 'listen_native.dart'"));
    expect(door,
        contains("if (dart.library.js_interop) 'listen_unsupported.dart'"));
  });

  test('the stand-in names everything the app asks the door for', () {
    final stub = read('lib/features/listen/listen_unsupported.dart');
    for (final name in [
      'class ListenChain',
      'deviceListenChain(',
      'savableListenLanguages()',
      'listenDownloads(',
      'class ListenInLanguageBar',
    ]) {
      expect(stub, contains(name), reason: name);
    }
    // And pulls in none of what it stands in for.
    for (final heavy in ['ffmpeg', 'listen_chain.dart', 'listen_device.dart']) {
      expect(stub, isNot(contains(heavy)), reason: heavy);
    }
  });

  test('PDF reading is asked for only where it exists, so the web build '
      'drops the PDF page rebuilding too', () {
    expect(read('lib/features/intake/document_intake.dart'),
        contains('pdfReadingAvailable && '));
    expect(read('lib/features/intake/share_intake.dart'),
        contains('if (!pdfReadingAvailable)'));
  });
}
