// Campaign 7 ("audiobooks are a door"), ADR-0013: a minimal pure-Dart
// parser over the file's own boxes — only the chapter track/chpl atom
// (moov/udta/chpl, the "Nero chapters" shape most audiobook tooling
// writes), never a general MP4 parser. Byte layout verified against
// ffmpeg's own `mov_read_chpl` (libavformat/mov.c), not guessed:
// version(1) + flags(3) [+ reserved(4) iff version != 0] + count(1), then
// per chapter: start(8, 100ns ticks) + title_len(1) + title(UTF-8).
import 'package:intake_core/intake_core.dart';
import 'package:test/test.dart';

import 'fixtures/m4b_fixtures.dart' as fx;

void main() {
  group('parseM4bChapters', () {
    test('reads title and start time (100ns ticks -> ms) for each chapter',
        () {
      final bytes = fx.m4bWithChapters([
        (0, 'Opening'),
        (600000000, 'Chapter One'), // 60s
        (1800000000, 'Chapter Two'), // 180s
      ]);
      final chapters = parseM4bChapters(bytes);
      expect(chapters, hasLength(3));
      expect(chapters[0].title, 'Opening');
      expect(chapters[0].startMs, 0);
      expect(chapters[1].title, 'Chapter One');
      expect(chapters[1].startMs, 60000);
      expect(chapters[2].title, 'Chapter Two');
      expect(chapters[2].startMs, 180000);
    });

    test('a UTF-8 title with non-ASCII characters round-trips', () {
      final bytes = fx.m4bWithChapters([(0, 'Café — Ch. 1')]);
      expect(parseM4bChapters(bytes).single.title, 'Café — Ch. 1');
    });

    test('a version-1 chpl atom (the extra reserved field) is still read',
        () {
      final bytes = fx.m4bWithVersion1Chpl([(0, 'Intro'), (1200000000, 'Two')]);
      final chapters = parseM4bChapters(bytes);
      expect(chapters.map((c) => c.title), ['Intro', 'Two']);
      expect(chapters[1].startMs, 120000);
    });

    test('no chpl anywhere is an empty list, never a throw', () {
      expect(parseM4bChapters(fx.m4bWithoutChapters()), isEmpty);
    });

    test('a moov with no udta at all is an empty list, never a throw', () {
      expect(parseM4bChapters(fx.m4bWithoutUdta()), isEmpty);
    });

    test('no moov in the buffer at all (a bounded read that never reached '
        'it) is an empty list, never a throw', () {
      expect(parseM4bChapters(fx.noMoovAtAll()), isEmpty);
    });

    test('a truncated chpl atom returns the chapters that parsed cleanly '
        'before the cut, never throws', () {
      final chapters = parseM4bChapters(fx.m4bWithTruncatedChpl());
      expect(chapters, hasLength(1));
      expect(chapters.single.title, 'Chapter One');
    });

    test('an empty buffer is an empty list, never a throw', () {
      expect(parseM4bChapters(const []), isEmpty);
    });

    test('zero declared chapters is an empty list', () {
      expect(parseM4bChapters(fx.m4bWithChapters(const [])), isEmpty);
    });
  });
}
