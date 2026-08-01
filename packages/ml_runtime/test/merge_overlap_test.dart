import 'package:test/test.dart';
import 'package:ml_runtime/ml_runtime.dart';

/// The overlap-merge law (proposal-2 §9, step 4): windowed transcription
/// (30s windows, 5s overlap) produces chunks that overlap in time; the merge
/// resolves every overlap BY TIMESTAMP MIDPOINT.
///
/// Two rules, both midpoint-governed:
///  - DUPLICATES (the same speech transcribed by both windows): two chunks
///    whose midpoints each fall inside the other's range are one utterance;
///    the longer transcription wins (ties: the later-sorted one — the later
///    window had more context).
///  - ADJACENCY (distinct speech with ragged edges): the contested interval
///    is split at its midpoint; word timings follow their own midpoints.
///
/// Output invariant: chunks tile — sorted, never overlapping (touching ok).
void main() {
  TranscriptChunk c(String text, int t0, int t1, {List<WordTiming>? words}) =>
      TranscriptChunk(text: text, tStartMs: t0, tEndMs: t1, words: words);

  group('mergeOverlap — trivial cases', () {
    test('empty in, empty out', () {
      expect(mergeOverlap(const []), isEmpty);
    });

    test('a single chunk passes through unchanged', () {
      final only = c('hello', 0, 1200);
      expect(mergeOverlap([only]), [only]);
    });

    test('non-overlapping chunks pass through unchanged', () {
      final a = c('one', 0, 1000);
      final b = c('two', 1500, 2500);
      expect(mergeOverlap([a, b]), [a, b]);
    });
  });

  group('mergeOverlap — the exact-boundary case', () {
    test('chunks that touch exactly (tEnd == tStart) are NOT an overlap', () {
      final a = c('first sentence', 0, 2000);
      final b = c('second sentence', 2000, 4000);
      final merged = mergeOverlap([a, b]);
      expect(merged, [a, b], reason: 'touching is tiling, not overlap');
    });
  });

  group('mergeOverlap — adjacency (ragged window edges)', () {
    test('a slight overlap between distinct chunks is cut at the overlap midpoint', () {
      // Overlap region is [2000, 2400]; its midpoint is 2200.
      final a = c('first', 0, 2400);
      final b = c('second', 2000, 5000);
      final merged = mergeOverlap([a, b]);
      expect(merged.length, 2);
      expect(merged[0].text, 'first');
      expect(merged[0].tStartMs, 0);
      expect(merged[0].tEndMs, 2200);
      expect(merged[1].text, 'second');
      expect(merged[1].tStartMs, 2200);
      expect(merged[1].tEndMs, 5000);
    });

    test('word timings follow their own midpoints across the cut', () {
      // Cut lands at 2200. "fox" (mid 2150) stays left; "jumps" (mid 2300)
      // belongs right — it is dropped from the left chunk and kept in the
      // right one.
      final a = c('the fox jumps', 0, 2400, words: [
        WordTiming(word: 'the', tStartMs: 0, tEndMs: 400),
        WordTiming(word: 'fox', tStartMs: 1900, tEndMs: 2400),
        WordTiming(word: 'jumps', tStartMs: 2200, tEndMs: 2400),
      ]);
      final b = c('jumps over', 2000, 5000, words: [
        WordTiming(word: 'jumps', tStartMs: 2200, tEndMs: 2400),
        WordTiming(word: 'over', tStartMs: 2400, tEndMs: 3000),
      ]);
      final merged = mergeOverlap([a, b]);
      expect(merged[0].words!.map((w) => w.word), ['the', 'fox']);
      expect(merged[1].words!.map((w) => w.word), ['jumps', 'over']);
    });
  });

  group('mergeOverlap — duplicates (the 30s-window / 5s-overlap recipe)', () {
    test('the same speech seen by both windows collapses to one chunk; the longer wins', () {
      // Window 1 [0..30000] heard the tail cut off; window 2 [25000..60000]
      // heard it whole. Mutual midpoint containment: 26000 in [24500,29500]
      // and 27000 in [24000,28000].
      final fromWin1 = c('the quick brown fox', 24000, 28000);
      final fromWin2 = c('the quick brown fox jumps', 24500, 29500);
      final merged = mergeOverlap([fromWin1, fromWin2]);
      expect(merged.length, 1);
      expect(merged.single.text, 'the quick brown fox jumps');
      expect(merged.single.tStartMs, 24500);
      expect(merged.single.tEndMs, 29500);
    });

    test('equal-duration duplicates: the later-sorted one wins (deterministic)', () {
      final earlier = c('hello word', 1000, 3000);
      final later = c('hello world', 1200, 3200);
      expect(mergeOverlap([earlier, later]).single.text, 'hello world');
    });

    test('a full two-window stitch tiles cleanly', () {
      // Window 1 [0..30000]:
      final w1 = [
        c('it begins', 0, 6000),
        c('and continues', 6000, 24000),
        c('the quick brown fox', 24000, 28000), // cut at window edge
      ];
      // Window 2 [25000..60000]:
      final w2 = [
        c('the quick brown fox jumps', 24500, 29500), // duplicate, complete
        c('over the lazy dog', 29500, 33000),
        c('and sleeps', 33000, 36000),
      ];
      final merged = mergeOverlap([...w1, ...w2]);
      expect(merged.map((x) => x.text), [
        'it begins',
        'and continues',
        'the quick brown fox jumps',
        'over the lazy dog',
        'and sleeps',
      ]);
      // Tiling invariant: sorted, never overlapping.
      for (var i = 0; i + 1 < merged.length; i++) {
        expect(merged[i].tEndMs, lessThanOrEqualTo(merged[i + 1].tStartMs));
      }
    });
  });

  group('mergeOverlap — out-of-order input', () {
    test('input order does not change the result', () {
      final chunks = [
        c('first', 0, 2400),
        c('second', 2000, 5000),
        c('third', 5000, 7000),
      ];
      final forward = mergeOverlap(chunks);
      final backward = mergeOverlap(chunks.reversed.toList());
      expect(backward, forward);
    });

    test('a duplicate arriving before its twin still merges', () {
      final fromWin2 = c('the quick brown fox jumps', 24500, 29500);
      final fromWin1 = c('the quick brown fox', 24000, 28000);
      final merged = mergeOverlap([fromWin2, fromWin1]);
      expect(merged.single.text, 'the quick brown fox jumps');
    });
  });

  group('mergeOverlap — laws', () {
    test('merging is idempotent', () {
      final chunks = [
        c('a', 0, 2400),
        c('b', 2000, 5000),
        c('the quick brown fox', 24000, 28000),
        c('the quick brown fox jumps', 24500, 29500),
      ];
      final once = mergeOverlap(chunks);
      expect(mergeOverlap(once), once);
    });

    test('the input list is not mutated', () {
      final chunks = [c('b', 2000, 5000), c('a', 0, 2400)];
      final snapshot = List.of(chunks);
      mergeOverlap(chunks);
      expect(chunks, snapshot);
    });
  });

  group('TranscriptChunk validation', () {
    test('tEnd before tStart is rejected', () {
      expect(() => c('bad', 100, 50), throwsArgumentError);
    });

    test('WordTiming tEnd before tStart is rejected', () {
      expect(() => WordTiming(word: 'w', tStartMs: 10, tEndMs: 5),
          throwsArgumentError);
    });
  });
}
