/// The content spine (ADR-0002).
///
/// Everything a household consumes — podcast episode, article, EPUB chapter,
/// feed item, pasted text — normalizes to one shape: a [Spine] of ordered
/// [Segment]s with per-language [Layer]s and audio [Alignment]s over them.
///
/// The cursor law: a [Position] is (segmentIdx, wordIdx) and NOTHING else —
/// never a modality, never a language. Renderers project it. That is what
/// makes "stop listening in the car, resume reading at the same sentence,
/// possibly in another language" a row read instead of a migration.
library;

enum SegmentKind { prose, heading, code, table, figure }

enum LayerKind { original, transcript, mt, human }

enum Modality { read, listen, speak }

enum WorkKind { book, article, episode, courseIntake, generated, note }

enum Persistence { work, ephemeron }

/// The atom of cross-modal identity: one sentence/block of a work.
class Segment {
  final int idx;
  final SegmentKind kind;
  final String text;
  const Segment({required this.idx, required this.kind, required this.text});
}

/// Per-segment text in one language, with provenance.
class Layer {
  final int segmentIdx;
  final String lang;
  final LayerKind kind;
  final String text;
  const Layer(
      {required this.segmentIdx,
      required this.lang,
      required this.kind,
      required this.text});
}

/// A segment's span in the work's audio, if any.
class Alignment {
  final int segmentIdx;
  final int tStartMs;
  final int tEndMs;
  const Alignment(
      {required this.segmentIdx, required this.tStartMs, required this.tEndMs});
}

/// Where a profile is in a work. [lastModality] is a display hint only —
/// no projection may read it (enforced by test).
class Position {
  final int segmentIdx;
  final int wordIdx;
  final Modality lastModality;
  const Position(
      {required this.segmentIdx,
      required this.wordIdx,
      required this.lastModality});
}

/// Work identity + the sovereignty bit: ephemera decay, works persist.
class Work {
  final String id;
  final WorkKind kind;
  final Persistence persistence;
  final int firstSeenEpochDay;
  const Work(
      {required this.id,
      required this.kind,
      required this.persistence,
      required this.firstSeenEpochDay});

  /// Promotion is the user's hand (extract, pin, finish). Idempotent.
  Work promote() => Work(
      id: id,
      kind: kind,
      persistence: Persistence.work,
      firstSeenEpochDay: firstSeenEpochDay);
}

class Spine {
  final List<Segment> segments;
  final List<Layer> layers;

  /// Sorted by [Alignment.tStartMs]; construction sorts a copy so callers
  /// may pass transcript order.
  final List<Alignment> alignments;

  Spine(
      {required this.segments,
      required this.layers,
      required List<Alignment> alignments})
      : alignments = List.of(alignments)
          ..sort((a, b) => a.tStartMs.compareTo(b.tStartMs));

  /// Audio time → position. Out-of-range clamps to the first/last aligned
  /// segment; a time inside a silence gap resolves to the PRECEDING segment
  /// (the cursor must not jump ahead during a pause in speech).
  Position positionAtAudioTime(int tMs) {
    assert(alignments.isNotEmpty, 'positionAtAudioTime needs alignments');
    var current = alignments.first;
    for (final a in alignments) {
      if (a.tStartMs > tMs) break;
      current = a;
    }
    return Position(
        segmentIdx: current.segmentIdx,
        wordIdx: 0,
        lastModality: Modality.listen);
  }

  /// Position → text, in [lang] when that segment has such a layer, else the
  /// segment's canonical text. The modality on [pos] is deliberately unread.
  String projectText(Position pos, {String? lang}) {
    if (lang != null) {
      for (final l in layers) {
        if (l.segmentIdx == pos.segmentIdx && l.lang == lang) return l.text;
      }
    }
    return segments[pos.segmentIdx].text;
  }

  /// Position → audio start time. An unaligned segment (a heading inserted
  /// between spoken sentences) resumes at the nearest PRECEDING aligned
  /// segment's start, so play never skips content the listener hasn't heard.
  int projectAudioTime(Position pos) {
    assert(alignments.isNotEmpty, 'projectAudioTime needs alignments');
    var best = alignments.first;
    for (final a in alignments) {
      if (a.segmentIdx > pos.segmentIdx) break;
      best = a;
    }
    return best.tStartMs;
  }
}

/// ADR-0003 law 2, as a pure verdict: ids of ephemera whose retention window
/// has fully passed. Day arithmetic is whole-epoch-day (study_core
/// convention); the boundary day itself survives.
List<String> sweepEphemera(List<Work> works,
    {required int todayEpochDay, int retentionDays = 30}) {
  return [
    for (final w in works)
      if (w.persistence == Persistence.ephemeron &&
          todayEpochDay - w.firstSeenEpochDay > retentionDays)
        w.id
  ];
}
