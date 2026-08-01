// Campaign 9 Phase 2e (ADR-0015 Decision 3): the work -> lock-screen-tag
// mapping, isolated from just_audio_background's own MediaItem type so it
// stays widget-testable without a platform channel in reach. This is the
// honest boundary the phase draws: what reaches the tag is provable here;
// how the lock screen RENDERS it is device-only and is not claimed by any
// test in this file.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/media_item_mapping.dart';

Work _work({
  int id = 1,
  String title = 'The Long Way Home',
}) =>
    Work(
      id: id,
      profileId: 1,
      kind: 'episode',
      title: title,
      sourceUrl: 'https://cast.test/1.mp3',
      lang: 'en',
      persistence: 'work',
      firstSeenEpochDay: 100,
      pinned: false,
      finishedEpochDay: null,
      showTranslationLayer: false,
      activeTranslationLang: null,
    );

void main() {
  group('lockScreenTagFor', () {
    test('id and title always come from the work, never invented', () {
      final info = lockScreenTagFor(_work(id: 42, title: 'Meditations'));
      expect(info.id, '42');
      expect(info.title, 'Meditations');
    });

    test('album carries the caller-supplied feed title', () {
      final info =
          lockScreenTagFor(_work(), album: 'The Daily Something Podcast');
      expect(info.album, 'The Daily Something Podcast');
    });

    test('a blank feed title (never resolved) reads as no album, not an '
        'empty string on the lock screen', () {
      final info = lockScreenTagFor(_work(), album: '');
      expect(info.album, isNull);
    });

    test('no album given (the audiobook path, which has no feed) is null',
        () {
      final info = lockScreenTagFor(_work());
      expect(info.album, isNull);
    });

    test('no artwork file given means no artUri', () {
      final info = lockScreenTagFor(_work());
      expect(info.artUri, isNull);
    });

    test('an artwork file that does not exist on disk means no artUri — a '
        'deterministic path is not proof a file was ever downloaded',
        () {
      final dir = Directory.systemTemp.createTempSync('trellis-mediaitem');
      addTearDown(() => dir.deleteSync(recursive: true));
      final missing = File('${dir.path}/never-downloaded.img');

      final info = lockScreenTagFor(_work(), artworkFile: missing);

      expect(info.artUri, isNull);
    });

    test('an artwork file that DOES exist on disk becomes artUri', () {
      final dir = Directory.systemTemp.createTempSync('trellis-mediaitem');
      addTearDown(() => dir.deleteSync(recursive: true));
      final art = File('${dir.path}/42.img')..writeAsBytesSync([1, 2, 3]);

      final info = lockScreenTagFor(_work(), artworkFile: art);

      expect(info.artUri, Uri.file(art.path));
    });
  });
}
