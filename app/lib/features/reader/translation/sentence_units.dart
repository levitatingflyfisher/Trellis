/// The canonical per-segment sentence numbering (ADR-0008 "Babel" Phase
/// 3): both the translation batch job (writing [TranslationSentence] rows)
/// and the reader's scroll-mode display and speak-loop substitution
/// (reading them) key off [sentenceUnitsOf]'s (segIdx, sentenceIdx) pairs —
/// the ONE place this numbering is decided, so the writer and the readers
/// can never drift into disagreeing about which sentence index N means.
/// Always called over a work's CANONICAL segments (`_original` in
/// reader_screen.dart) — never a language-projected list, whose
/// `splitSentences` boundaries can differ from the English original's.
library;

import 'package:loom_core/loom_core.dart' as core;

import '../../../db/database.dart';

/// One translatable English sentence: segment [segIdx] (the segment's OWN
/// `Segment.idx`, never its position in whatever list it came from — a
/// work whose segments don't start at 0 must still key rows correctly),
/// per-segment [sentenceIdx] (the RAW index `core.splitSentences` assigns
/// within that segment), and its verbatim [text].
class TranslatableSentence {
  final int segIdx;
  final int sentenceIdx;
  final String text;
  const TranslatableSentence(
      {required this.segIdx, required this.sentenceIdx, required this.text});
}

/// Every sentence worth translating across [segments] — the same
/// "speakable" filter (prose/heading, non-blank) the speak loop's own
/// `_remainingSpeechUnits` in reader_screen.dart applies, so a work's
/// translated-sentence count always matches what a listener would have
/// heard. code/table/figure segments carry nothing sentence-shaped to
/// translate, the same reason they carry nothing to speak.
List<TranslatableSentence> sentenceUnitsOf(List<core.Segment> segments) {
  final units = <TranslatableSentence>[];
  for (final seg in segments) {
    final speakable = seg.kind == core.SegmentKind.prose ||
        seg.kind == core.SegmentKind.heading;
    if (!speakable || seg.text.trim().isEmpty) continue;
    final sentences = core.splitSentences(seg.text);
    for (var i = 0; i < sentences.length; i++) {
      final text = sentences[i].text;
      if (text.trim().isEmpty) continue;
      units.add(TranslatableSentence(segIdx: seg.idx, sentenceIdx: i, text: text));
    }
  }
  return units;
}

/// The store's staleness law (ADR-0008), made a function: a stored
/// [TranslationSentence]'s `sourceText` is compared against
/// [currentSourceText] at lookup, so a re-ingest that reshapes a work's
/// segments reads a stale row as missing — falling back to English —
/// instead of pairing a translation with a sentence it was never
/// translated from. The ONE place both the scroll-mode dual display and
/// the speak loop's per-sentence substitution look a translation up
/// through, so the law can't drift between the two call sites.
String? translatedTextFor({
  required Map<(int, int), TranslationSentence> stored,
  required int segIdx,
  required int sentenceIdx,
  required String currentSourceText,
}) {
  final row = stored[(segIdx, sentenceIdx)];
  if (row == null || row.sourceText != currentSourceText) return null;
  return row.body;
}
