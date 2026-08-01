/// Transcript chunks and the overlap-merge law.
///
/// Windowed transcription (proposal-2 §9: 30s windows, 5s overlap) produces
/// chunks whose time ranges overlap at window seams. [mergeOverlap] resolves
/// every overlap **by timestamp midpoint** — one rule, applied twice:
///
///  * **Duplicates.** Two chunks whose midpoints each fall inside the other's
///    range are the same utterance heard by both windows. The longer
///    transcription wins (it heard more); on an exact duration tie the
///    later-sorted chunk wins (the later window had more context).
///  * **Adjacency.** Distinct chunks with ragged overlapping edges split the
///    contested interval at its midpoint; each word timing follows its own
///    midpoint to whichever side it lands on.
///
/// Timestamps are integer milliseconds, matching `loom_core`'s `Alignment`
/// (`tStartMs`/`tEndMs`). Word-level timing is best-effort by contract
/// (ADR-0002); sentence-level is the guarantee.
library;

/// A single word with its best-effort time range.
class WordTiming {
  final String word;
  final int tStartMs;
  final int tEndMs;

  WordTiming({required this.word, required this.tStartMs, required this.tEndMs}) {
    if (tEndMs < tStartMs) {
      throw ArgumentError('WordTiming "$word": tEndMs < tStartMs');
    }
  }

  int get midpointMs => (tStartMs + tEndMs) ~/ 2;

  @override
  bool operator ==(Object other) =>
      other is WordTiming &&
      other.word == word &&
      other.tStartMs == tStartMs &&
      other.tEndMs == tEndMs;

  @override
  int get hashCode => Object.hash(word, tStartMs, tEndMs);

  @override
  String toString() => 'WordTiming("$word", $tStartMs..$tEndMs)';
}

/// One transcribed span: text plus its time range, with optional word
/// timings (`null` when the engine was asked not to produce them).
class TranscriptChunk {
  final String text;
  final int tStartMs;
  final int tEndMs;
  final List<WordTiming>? words;

  TranscriptChunk({
    required this.text,
    required this.tStartMs,
    required this.tEndMs,
    List<WordTiming>? words,
  }) : words = words == null ? null : List.unmodifiable(words) {
    if (tEndMs < tStartMs) {
      throw ArgumentError('TranscriptChunk "$text": tEndMs < tStartMs');
    }
  }

  int get midpointMs => (tStartMs + tEndMs) ~/ 2;
  int get durationMs => tEndMs - tStartMs;

  TranscriptChunk copyWith({
    String? text,
    int? tStartMs,
    int? tEndMs,
    List<WordTiming>? words,
    bool clearWords = false,
  }) =>
      TranscriptChunk(
        text: text ?? this.text,
        tStartMs: tStartMs ?? this.tStartMs,
        tEndMs: tEndMs ?? this.tEndMs,
        words: clearWords ? null : (words ?? this.words),
      );

  @override
  bool operator ==(Object other) =>
      other is TranscriptChunk &&
      other.text == text &&
      other.tStartMs == tStartMs &&
      other.tEndMs == tEndMs &&
      _wordsEqual(other.words, words);

  static bool _wordsEqual(List<WordTiming>? a, List<WordTiming>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(text, tStartMs, tEndMs, Object.hashAll(words ?? const []));

  @override
  String toString() => 'TranscriptChunk("$text", $tStartMs..$tEndMs)';
}

/// Merges overlapping transcript chunks by timestamp midpoint.
///
/// Input order is irrelevant (chunks are sorted by midpoint, ties by start,
/// then by input position — fully deterministic). The input list is not
/// mutated. Output invariant: chunks tile — ascending, never overlapping;
/// touching exactly (`a.tEndMs == b.tStartMs`) is tiling, not overlap.
/// The function is idempotent.
List<TranscriptChunk> mergeOverlap(List<TranscriptChunk> chunks) {
  if (chunks.length <= 1) return List.unmodifiable(chunks);

  // Decorate-sort with the original index: List.sort is not stable, so the
  // index makes the order fully deterministic.
  final indexed = List.generate(chunks.length, (i) => (i, chunks[i]));
  indexed.sort((a, b) {
    final byMid = a.$2.midpointMs.compareTo(b.$2.midpointMs);
    if (byMid != 0) return byMid;
    final byStart = a.$2.tStartMs.compareTo(b.$2.tStartMs);
    if (byStart != 0) return byStart;
    return a.$1.compareTo(b.$1);
  });

  final out = <TranscriptChunk>[];
  for (final (_, next) in indexed) {
    var cur = next;
    while (out.isNotEmpty && cur.tStartMs < out.last.tEndMs) {
      final prev = out.removeLast();
      if (_isDuplicate(prev, cur)) {
        // Same utterance from two windows: the longer transcription wins;
        // exact tie -> the later-sorted one (more context in that window).
        cur = cur.durationMs >= prev.durationMs ? cur : prev;
        // The winner may still overlap what came before `prev` — loop.
      } else {
        // Distinct speech with ragged edges: cut the contested interval at
        // its midpoint.
        final lo = cur.tStartMs > prev.tStartMs ? cur.tStartMs : prev.tStartMs;
        final hi = cur.tEndMs < prev.tEndMs ? cur.tEndMs : prev.tEndMs;
        final cut = (lo + hi) ~/ 2;
        out.add(_trimEnd(prev, cut));
        cur = _trimStart(cur, cut);
        break; // prev now ends exactly where cur starts: tiled.
      }
    }
    out.add(cur);
  }
  return List.unmodifiable(out);
}

/// Two chunks describe the same audio when each one's midpoint lies inside
/// the other's range — slight edge overlaps between *distinct* chunks never
/// satisfy both containments.
bool _isDuplicate(TranscriptChunk a, TranscriptChunk b) =>
    a.midpointMs >= b.tStartMs &&
    a.midpointMs <= b.tEndMs &&
    b.midpointMs >= a.tStartMs &&
    b.midpointMs <= a.tEndMs;

TranscriptChunk _trimEnd(TranscriptChunk c, int cut) => c.copyWith(
      tEndMs: cut,
      words: c.words?.where((w) => w.midpointMs < cut).toList(),
    );

TranscriptChunk _trimStart(TranscriptChunk c, int cut) => c.copyWith(
      tStartMs: cut,
      words: c.words?.where((w) => w.midpointMs >= cut).toList(),
    );
