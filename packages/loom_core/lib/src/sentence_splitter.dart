/// Sentence-boundary segmentation (the neural-TTS campaign, ADR-0006):
/// speak mode's unit of work moves from the whole block to the sentence, so
/// a paragraph reads as several short utterances/synthesis calls instead of
/// one long one — the fix for the platform TTS "long-utterance stall".
///
/// Abbreviation tolerance is deliberately modest ("Dr. Smith" over
/// "Tues. morning" — a wrong SPLIT costs a listener one extra breath). A
/// wrong WORD INDEX is a different kind of bug: [Sentence.firstWordIdx]
/// feeds straight into `globalWordIndex`/`cursorAt` (reader_logic.dart) and
/// from there into `savePosition`'s segmentIdx+wordIdx (ADR-0002) — so it
/// is never re-derived by a second, cheaper word-counting rule. It is read
/// straight off [tokenizeDocument]'s own word count for the sentence's
/// prefix, the same authority the cursor law already trusts. A naive
/// whitespace count would silently drift on any block containing a
/// hyphenated compound (tokenizer.dart splits "well-known" into two display
/// words) — see sentence_splitter_test.dart's discriminating case.
library;

import 'spine.dart';
import 'tokenizer.dart';

/// One sentence within a block: its verbatim text (never a re-joining of
/// display tokens, which would speak abbreviated URLs and repeated hyphen
/// parts) and the index of its first word, in the SAME block-relative
/// coordinate space as `Position.wordIdx`.
class Sentence {
  final String text;
  final int firstWordIdx;
  const Sentence({required this.text, required this.firstWordIdx});

  @override
  String toString() => 'Sentence("$text", @$firstWordIdx)';
}

/// Terminal punctuation (one or more of `.!?`) followed by whitespace or
/// end-of-string. Deliberately does NOT match punctuation immediately
/// followed by a closing quote/paren — an embedded "quoted!" exclamation
/// stays inside its sentence rather than risking a mid-quote clip; the
/// safe failure mode is one long pause over the whole quote.
final _sentenceEndRe = RegExp(r'[.!?]+(?=\s|$)');
final _whitespaceRe = RegExp(r'\s+');

/// Common abbreviations whose trailing period is not a sentence end.
/// Modest, not exhaustive — see the KNOWN LIMITATION test.
const _abbreviations = {
  'mr', 'mrs', 'ms', 'dr', 'prof', 'sr', 'jr', 'st', 'vs', 'etc', 'e.g',
  'i.e', 'no', 'fig', 'vol', 'approx', 'ca', 'cf', 'mt', 'ave', 'blvd',
};

bool _isAbbreviation(String wordBeforePeriod) {
  final bare = wordBeforePeriod.toLowerCase();
  if (bare.isEmpty) return false;
  // A single letter is almost always an initial ("J. K. Rowling"), not a
  // sentence end.
  if (bare.length == 1) return true;
  return _abbreviations.contains(bare);
}

/// Splits [text] into sentences (see library docs for the tolerance and
/// the [Sentence.firstWordIdx] exactness contract).
List<Sentence> splitSentences(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const [];

  final sentences = <Sentence>[];
  var start = 0;

  void addSentence(int end) {
    final sentenceText = trimmed.substring(start, end).trim();
    if (sentenceText.isEmpty) return;
    final prefix = trimmed.substring(0, start);
    final firstWordIdx = prefix.trim().isEmpty
        ? 0
        : tokenizeDocument(
                [Segment(idx: 0, kind: SegmentKind.prose, text: prefix)])
            .words
            .length;
    sentences.add(Sentence(text: sentenceText, firstWordIdx: firstWordIdx));
  }

  for (final m in _sentenceEndRe.allMatches(trimmed)) {
    final beforePunct = trimmed.substring(start, m.start);
    final lastWord = beforePunct.trim().split(_whitespaceRe).lastOrNull ?? '';
    if (_isAbbreviation(lastWord)) continue; // not a real boundary
    addSentence(m.end);
    start = m.end;
  }
  if (start < trimmed.length) addSentence(trimmed.length);

  return sentences;
}

extension _LastOrNull<T> on List<T> {
  T? get lastOrNull => isEmpty ? null : last;
}
