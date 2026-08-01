/// CJK (Chinese/Japanese/Korean) script detection and character-level
/// segmentation — the baseline this campaign ships without a dictionary
/// (Campaign 8 "Babel widens" Phase 3).
///
/// UAX #29 (Unicode word boundaries) explicitly punts dictionary-based
/// segmentation of Han ideographs and Hiragana to implementations; its OWN
/// default algorithm, absent a dictionary, already breaks between every
/// pair of adjacent ideographs (there is no "don't break" rule joining
/// them, unlike AHLetter x AHLetter for Latin script) and keeps a run of
/// Katakana together (rule WB13). That default IS the baseline this
/// module implements: one Han ideograph = one unit, a maximal Katakana
/// run = one unit, Hiragana falls to one character per unit. The last of
/// those is a real ceiling for Japanese: a grammatical word like 食べる
/// ("to eat") splits into 食/べ/る here rather than staying whole — a
/// dictionary segmenter (TinySegmenter) is the honest fix, not shipped
/// this phase (docs/reference/mt-models.md records the ceiling).
///
/// Used by both [tokenizer.dart]'s RSVP/display word stream and
/// [sentence_splitter.dart]'s speak-mode boundaries — the ONE place CJK
/// script detection is decided, so the two consumers can't drift into
/// disagreeing about what counts as CJK.
library;

/// CJK Unified Ideographs (the common block), Extension A, the
/// compatibility block, and the supplementary-plane extensions reachable
/// by real text — covers simplified and traditional Chinese, and the
/// kanji Japanese text uses.
bool isHanIdeograph(int cp) =>
    (cp >= 0x4E00 && cp <= 0x9FFF) ||
    (cp >= 0x3400 && cp <= 0x4DBF) ||
    (cp >= 0xF900 && cp <= 0xFAFF) ||
    (cp >= 0x20000 && cp <= 0x2FA1F);

/// The Hiragana block (small kana extensions excluded — rare enough in
/// real prose that the one-character-per-unit default is not worth the
/// extra range checks).
bool isHiragana(int cp) => cp >= 0x3041 && cp <= 0x309F;

/// The Katakana block plus the small Katakana phonetic extensions.
bool isKatakana(int cp) =>
    (cp >= 0x30A0 && cp <= 0x30FF) || (cp >= 0x31F0 && cp <= 0x31FF);

bool isCjkCodepoint(int cp) =>
    isHanIdeograph(cp) || isHiragana(cp) || isKatakana(cp);

/// Ideographic/fullwidth sentence-final punctuation — the CJK counterpart
/// of ASCII `.!?`. CJK prose carries no inter-sentence whitespace, so
/// this campaign's ASCII sentence-boundary rule (which requires trailing
/// whitespace, to tell "Mr. Smith" from a real sentence end) cannot apply
/// here — these codepoints are unambiguously sentence-final on their own,
/// which is exactly why the scripts use distinct punctuation instead of
/// overloading a period the way ASCII does.
bool isCjkSentenceTerminator(int cp) =>
    cp == 0x3002 || // 。 ideographic full stop
    cp == 0xFF01 || // ！ fullwidth exclamation mark
    cp == 0xFF1F; // ？ fullwidth question mark

/// Other CJK punctuation this segmenter treats as trailing — folded onto
/// the unit before it, never a unit of its own — the same way the Latin
/// tokenizer keeps "word," together rather than splitting off the comma.
bool isCjkTrailingPunctuation(int cp) =>
    isCjkSentenceTerminator(cp) ||
    cp == 0x3001 || // 、 ideographic comma
    cp == 0xFF0C || // ， fullwidth comma
    cp == 0xFF1A || // ： fullwidth colon
    cp == 0xFF1B || // ； fullwidth semicolon
    cp == 0x300D || // 」 closing corner bracket
    cp == 0x300F; // 』 closing white corner bracket

/// True if any codepoint in [text] is CJK — the tokenizer's own gate for
/// routing a whitespace-delimited chunk through [segmentCjkRun] instead
/// of treating it as one Latin-style token.
bool containsCjk(String text) => text.runes.any(isCjkCodepoint);

/// Splits one run of text into display units under the baseline above:
/// each Han ideograph its own unit, a maximal Katakana run kept together,
/// Hiragana one character at a time, trailing punctuation folded onto the
/// unit before it. A non-CJK stretch embedded in the run (a product name,
/// a digit run) becomes its own maximal contiguous unit — the same shape
/// the whitespace tokenizer already gives plain Latin text, so a mixed
/// string like "iPhone15発売" reads naturally rather than exploding into
/// single characters where it shouldn't.
List<String> segmentCjkRun(String text) {
  final runes = text.runes.toList();
  final units = <String>[];
  var i = 0;
  while (i < runes.length) {
    final cp = runes[i];
    if (isCjkTrailingPunctuation(cp)) {
      if (units.isEmpty) {
        units.add(String.fromCharCode(cp));
      } else {
        units[units.length - 1] = units.last + String.fromCharCode(cp);
      }
      i++;
    } else if (isKatakana(cp)) {
      final start = i;
      while (i < runes.length && isKatakana(runes[i])) {
        i++;
      }
      units.add(String.fromCharCodes(runes.sublist(start, i)));
    } else if (isHanIdeograph(cp) || isHiragana(cp)) {
      units.add(String.fromCharCode(cp));
      i++;
    } else {
      final start = i;
      while (i < runes.length &&
          !isCjkCodepoint(runes[i]) &&
          !isCjkTrailingPunctuation(runes[i])) {
        i++;
      }
      units.add(String.fromCharCodes(runes.sublist(start, i)));
    }
  }
  return units;
}
