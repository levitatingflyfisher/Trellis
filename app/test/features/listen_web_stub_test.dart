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
      'lib/features/feeds/feed_detail_screen.dart',
    ]) {
      final text = read(user);
      expect(text, contains("listen/listen.dart'"), reason: user);
      for (final direct in [
        'listen_chain.dart',
        'listen_device.dart',
        'listen_jobs.dart',
        'listen_row_button.dart',
        'spoken_episode.dart',
        'make_ahead_jobs.dart',
        'make_ahead_switch.dart',
      ]) {
        expect(text, isNot(contains(direct)), reason: '$user imports $direct');
      }
    }
  });

  test('on the web no row gets a second button: the stand-in offers '
      'nothing and its button draws nothing', () {
    final stub = read('lib/features/listen/listen_unsupported.dart');
    expect(stub, contains('offerFor('));
    expect(
        RegExp(r'ListenOffer\? offerFor\([^)]*\)\s*=>\s*null;', dotAll: true)
            .hasMatch(stub),
        isTrue);
    final button = stub.substring(stub.indexOf('class ListenRowButton'));
    expect(
        button.substring(0, button.indexOf('\n}\n')),
        contains('Widget build(BuildContext context) => '
            'const SizedBox.shrink();'));
  });

  test('on the web no show has a make-ahead switch or line, and its door '
      'is the only way in', () {
    final stub = read('lib/features/listen/listen_unsupported.dart');
    expect(
        RegExp(r'MakeAheadOffer\? aheadOfferFor\(Feed feed\) => null;')
            .hasMatch(stub),
        isTrue);
    for (final name in ['class MakeAheadTile', 'class MakeAheadLine']) {
      final body = stub.substring(stub.indexOf(name));
      expect(
          body.substring(0, body.indexOf('\n}\n')),
          contains('Widget build(BuildContext context) => '
              'const SizedBox.shrink();'),
          reason: name);
    }
    expect(read('lib/features/listen/listen_native.dart'),
        contains("export 'make_ahead_switch.dart'"));
    expect(read('lib/features/feeds/feed_detail_screen.dart'),
        contains("listen/listen.dart'"));
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
      'class ListenJobs',
      'class ListenOffer',
      'deviceListenJobs(',
      'class ListenRowButton',
      'class MakeAheadOffer',
      'class MakeAheadTile',
      'class MakeAheadLine',
      'makeAheadPass()',
      'refreshVoices()',
      'get clearness',
      'chooseClearness(',
      'aheadOfferFor(',
      'setMakeAhead(',
    ]) {
      expect(stub, contains(name), reason: name);
    }
    // And pulls in none of what it stands in for.
    for (final heavy in [
      'ffmpeg',
      'listen_chain.dart',
      'listen_device.dart',
      'listen_jobs.dart',
      'listen_row_button.dart',
    ]) {
      expect(stub, isNot(contains(heavy)), reason: heavy);
    }
  });

  test('rows and the episode’s page offer only the languages that can be '
      'made for that episode', () {
    // Both ask the one owner, which is given the device's rule.
    expect(read('lib/features/listen/listen_device.dart'),
        contains('listenLanguagesFor(services, workLang: workLang, '
            'feedLang: feedLang)'));
    for (final user in [
      'lib/features/works/work_page.dart',
      'lib/features/episodes/episode_actions.dart',
    ]) {
      expect(read(user), isNot(contains('savableListenLanguages')),
          reason: user);
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
