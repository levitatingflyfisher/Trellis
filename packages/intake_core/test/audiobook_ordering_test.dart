// Campaign 7 ("audiobooks are a door"): file playback order. Natural sort
// solves the classic "1, 2, 10" problem a plain string sort gets wrong;
// [orderAudiobookFiles] prefers disc/track tags when EVERY file carries one,
// falling back to natural sort otherwise (ADR-0013 — nothing populates tags
// yet in Phase 1, but the law is real and tested on its own).
import 'package:intake_core/intake_core.dart';
import 'package:test/test.dart';

void main() {
  group('naturalSortAudiobookFiles', () {
    test('the classic 1, 2, 10 problem', () {
      expect(
        naturalSortAudiobookFiles(['track10.mp3', 'track2.mp3', 'track1.mp3']),
        ['track1.mp3', 'track2.mp3', 'track10.mp3'],
      );
    });

    test('double digits and single digits interleave by value', () {
      expect(
        naturalSortAudiobookFiles(['a10.mp3', 'a9.mp3', 'a2.mp3']),
        ['a2.mp3', 'a9.mp3', 'a10.mp3'],
      );
    });

    test('leading zeros do not change numeric value', () {
      expect(
        naturalSortAudiobookFiles(['file2.mp3', 'file010.mp3', 'file01.mp3']),
        ['file01.mp3', 'file2.mp3', 'file010.mp3'],
      );
    });

    test('case-insensitive on the non-numeric runs', () {
      expect(
        naturalSortAudiobookFiles(['Track2.mp3', 'track1.mp3']),
        ['track1.mp3', 'Track2.mp3'],
      );
    });

    test('disc-then-track path-shaped names sort disc-major', () {
      expect(
        naturalSortAudiobookFiles(
            ['CD2/03.mp3', 'CD1/10.mp3', 'CD1/02.mp3']),
        ['CD1/02.mp3', 'CD1/10.mp3', 'CD2/03.mp3'],
      );
    });

    test('a name with no digits at all never throws', () {
      expect(
        naturalSortAudiobookFiles(['intro.mp3', 'chapter.mp3']),
        ['chapter.mp3', 'intro.mp3'],
      );
    });

    test('empty input yields empty output', () {
      expect(naturalSortAudiobookFiles(const []), isEmpty);
    });
  });

  group('naturalCompareAudiobookNames', () {
    test('sorts a list of richer records by a name field without a '
        'name->path map (two files can share a display name)', () {
      final records = [
        (name: 'track10.mp3', path: '/a/track10.mp3'),
        (name: 'track2.mp3', path: '/b/track2.mp3'),
        (name: 'track2.mp3', path: '/c/track2.mp3'),
      ];
      records.sort((a, b) => naturalCompareAudiobookNames(a.name, b.name));
      expect(records.map((r) => r.path),
          ['/b/track2.mp3', '/c/track2.mp3', '/a/track10.mp3']);
    });
  });

  group('orderAudiobookFiles', () {
    test('prefers track tags when every file has one', () {
      final order = orderAudiobookFiles(
        ['b.mp3', 'a.mp3', 'c.mp3'],
        tags: const {
          'a.mp3': AudioTrackTag(track: 2),
          'b.mp3': AudioTrackTag(track: 1),
          'c.mp3': AudioTrackTag(track: 3),
        },
      );
      expect(order, ['b.mp3', 'a.mp3', 'c.mp3']);
    });

    test('disc is major, track is minor', () {
      final order = orderAudiobookFiles(
        ['x.mp3', 'y.mp3', 'z.mp3'],
        tags: const {
          'x.mp3': AudioTrackTag(disc: 2, track: 1),
          'y.mp3': AudioTrackTag(disc: 1, track: 2),
          'z.mp3': AudioTrackTag(disc: 1, track: 1),
        },
      );
      expect(order, ['z.mp3', 'y.mp3', 'x.mp3']);
    });

    test('a null disc sorts as disc 1', () {
      final order = orderAudiobookFiles(
        ['a.mp3', 'b.mp3'],
        tags: const {
          'a.mp3': AudioTrackTag(track: 2),
          'b.mp3': AudioTrackTag(disc: 1, track: 1),
        },
      );
      expect(order, ['b.mp3', 'a.mp3']);
    });

    test('a partial tag set (one file untagged) falls back to natural sort '
        'rather than a silently wrong partial order', () {
      final order = orderAudiobookFiles(
        ['track10.mp3', 'track2.mp3'],
        tags: const {'track10.mp3': AudioTrackTag(track: 1)},
      );
      expect(order, ['track2.mp3', 'track10.mp3']);
    });

    test('no tags at all falls back to natural sort', () {
      expect(
        orderAudiobookFiles(['track10.mp3', 'track2.mp3']),
        ['track2.mp3', 'track10.mp3'],
      );
    });
  });

  group('defaultAudiobookTitle', () {
    test('strips extension and a trailing track-number tail', () {
      expect(defaultAudiobookTitle(['My Book - 01.mp3']), 'My Book');
    });

    test('an underscore-separated track number is also stripped', () {
      expect(defaultAudiobookTitle(['My_Book_01.m4b']), 'My_Book');
    });

    test('a name with no trailing number is only extension-stripped', () {
      expect(defaultAudiobookTitle(['My Book.mp3']), 'My Book');
    });

    test('empty input falls back to a named placeholder', () {
      expect(defaultAudiobookTitle(const []), 'Untitled audiobook');
    });

    test('a name that is only a number falls back to the placeholder '
        'rather than an empty string', () {
      expect(defaultAudiobookTitle(['01.mp3']), 'Untitled audiobook');
    });
  });
}
