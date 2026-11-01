/// What Kokoro-82M v1.1-zh needs around misaki's phoneme string: the
/// token ids, the voice-style row, the speed curve, and a split for lines
/// over 510 phonemes.
library;

/// Kokoro-82M v1.1-zh's vocabulary, 171 symbols, copied from
/// `config.json` in huggingface.co/hexgrad/Kokoro-82M-v1.1-zh at
/// 01e7505bd6a7a2ac4975463114c3a7650a9f7218 (sha256 of the file
/// bc333efa5ce4ceff433c8c8e5d027a1eca0166001e4e4a62bea2d26ff7a46890),
/// Apache-2.0. Id 0 is the pad and is no symbol.
const Map<String, int> kokoroZhVocab = {
  ';': 1,
  ':': 2,
  ',': 3,
  '.': 4,
  '!': 5,
  '?': 6,
  '/': 7,
  '—': 9,
  '…': 10,
  '"': 11,
  '(': 12,
  ')': 13,
  '“': 14,
  '”': 15,
  ' ': 16,
  '\u{303}': 17,
  'ʣ': 18,
  'ʥ': 19,
  'ʦ': 20,
  'ʨ': 21,
  'ᵝ': 22,
  'ㄓ': 23,
  'A': 24,
  'I': 25,
  'ㄅ': 30,
  'O': 31,
  'ㄆ': 32,
  'Q': 33,
  'R': 34,
  'S': 35,
  'T': 36,
  'ㄇ': 37,
  'ㄈ': 38,
  'W': 39,
  'ㄉ': 40,
  'Y': 41,
  'ᵊ': 42,
  'a': 43,
  'b': 44,
  'c': 45,
  'd': 46,
  'e': 47,
  'f': 48,
  'ㄊ': 49,
  'h': 50,
  'i': 51,
  'j': 52,
  'k': 53,
  'l': 54,
  'm': 55,
  'n': 56,
  'o': 57,
  'p': 58,
  'q': 59,
  'r': 60,
  's': 61,
  't': 62,
  'u': 63,
  'v': 64,
  'w': 65,
  'x': 66,
  'y': 67,
  'z': 68,
  'ɑ': 69,
  'ɐ': 70,
  'ɒ': 71,
  'æ': 72,
  'ㄋ': 73,
  'ㄌ': 74,
  'β': 75,
  'ɔ': 76,
  'ɕ': 77,
  'ç': 78,
  'ㄍ': 79,
  'ɖ': 80,
  'ð': 81,
  'ʤ': 82,
  'ə': 83,
  'ㄎ': 84,
  'ㄦ': 85,
  'ɛ': 86,
  'ɜ': 87,
  'ㄏ': 88,
  'ㄐ': 89,
  'ɟ': 90,
  'ㄑ': 91,
  'ɡ': 92,
  'ㄒ': 93,
  'ㄔ': 94,
  'ㄕ': 95,
  'ㄗ': 96,
  'ㄘ': 97,
  'ㄙ': 98,
  '月': 99,
  'ㄚ': 100,
  'ɨ': 101,
  'ɪ': 102,
  'ʝ': 103,
  'ㄛ': 104,
  'ㄝ': 105,
  'ㄞ': 106,
  'ㄟ': 107,
  'ㄠ': 108,
  'ㄡ': 109,
  'ɯ': 110,
  'ɰ': 111,
  'ŋ': 112,
  'ɳ': 113,
  'ɲ': 114,
  'ɴ': 115,
  'ø': 116,
  'ㄢ': 117,
  'ɸ': 118,
  'θ': 119,
  'œ': 120,
  'ㄣ': 121,
  'ㄤ': 122,
  'ɹ': 123,
  'ㄥ': 124,
  'ɾ': 125,
  'ㄖ': 126,
  'ㄧ': 127,
  'ʁ': 128,
  'ɽ': 129,
  'ʂ': 130,
  'ʃ': 131,
  'ʈ': 132,
  'ʧ': 133,
  'ㄨ': 134,
  'ʊ': 135,
  'ʋ': 136,
  'ㄩ': 137,
  'ʌ': 138,
  'ɣ': 139,
  'ㄜ': 140,
  'ㄭ': 141,
  'χ': 142,
  'ʎ': 143,
  '十': 144,
  '压': 145,
  '言': 146,
  'ʒ': 147,
  'ʔ': 148,
  '阳': 149,
  '要': 150,
  '阴': 151,
  '应': 152,
  '用': 153,
  '又': 154,
  '中': 155,
  'ˈ': 156,
  'ˌ': 157,
  'ː': 158,
  '穵': 159,
  '外': 160,
  '万': 161,
  'ʰ': 162,
  '王': 163,
  'ʲ': 164,
  '为': 165,
  '文': 166,
  '瓮': 167,
  '我': 168,
  '3': 169,
  '5': 170,
  '1': 171,
  '2': 172,
  '4': 173,
  '元': 175,
  '云': 176,
  'ᵻ': 177,
};

/// The most phonemes Kokoro takes in one call (pipeline.py).
const int kokoroMaxPhonemes = 510;

/// One call's worth of input for Kokoro v1.1-zh.
class KokoroZhTokens {
  KokoroZhTokens(this.phonemes)
      : lenPs = phonemes.runes.length,
        inputIds = kokoroZhIds(phonemes);

  /// misaki's phoneme string.
  final String phonemes;

  /// `len(ps)` in Python: code points, counting the ones the vocabulary
  /// drops (the unknown mark ❓).
  final int lenPs;

  /// `[0] + [vocab[c] for c in ps if c in vocab] + [0]`.
  final List<int> inputIds;

  /// The voice pack row: `pack[len(ps) - 1]` (pipeline.py, `infer`).
  int get styleRow => styleRowFor(lenPs);

  /// Speed from the maker's own curve ([kokoroZhSpeed]).
  double get speed => kokoroZhSpeed(lenPs);
}

/// Token ids with the pad 0 at both ends; symbols not in the vocabulary
/// are dropped, as KModel does.
List<int> kokoroZhIds(String phonemes) => [
      0,
      for (final c in phonemes.runes)
        if (kokoroZhVocab[String.fromCharCode(c)] case final id?) id,
      0,
    ];

/// `len(ps) - 1`: the row of the voice pack (shape [510, 1, 256]) used as
/// the style vector.
int styleRowFor(int lenPs) => lenPs - 1;

/// `speed_callable` from the maker's samples/make_zh.py, lines 61 to 67
/// (huggingface.co/hexgrad/Kokoro-82M-v1.1-zh, Apache-2.0): 1.1 up to 83
/// phonemes, falling linearly to 0.88 at 183, then 0.88.
double kokoroZhSpeed(int lenPs) {
  var speed = 0.8;
  if (lenPs <= 83) {
    speed = 1;
  } else if (lenPs < 183) {
    speed = 1 - (lenPs - 83) / 500;
  }
  return speed * 1.1;
}

/// Splits a phoneme string longer than [max] into pieces of at most [max]
/// code points each. Kokoro's own pipeline truncates Chinese at 510; this
/// cuts instead, after the last mark of the first group of kokoro's
/// `waterfall_last` order that has one (`!.?…`, then `:;`, then `,—`),
/// moving past a closing `)` or `”` right after it. With no such mark it
/// cuts at the last word break (space or `/`, which is dropped), and only
/// then mid-word.
/// Pieces are stripped of spaces at their ends, as `tokens_to_ps` does.
List<String> splitKokoroPhonemes(String ps, {int max = kokoroMaxPhonemes}) {
  const waterfall = ['!.?…', ':;', ',—'];
  const bumps = [')', '”'];
  final out = <String>[];
  var rest = ps.runes.toList();
  String str(List<int> r) => String.fromCharCodes(r).trim();
  while (rest.length > max) {
    var cut = -1;
    for (final w in waterfall) {
      for (var i = max - 1; i >= 0; i--) {
        if (w.contains(String.fromCharCode(rest[i]))) {
          var z = i + 1;
          if (z < rest.length &&
              bumps.contains(String.fromCharCode(rest[z])) &&
              z + 1 <= max) {
            z++;
          }
          cut = z;
          break;
        }
      }
      if (cut > 0) break;
    }
    var skip = 0;
    if (cut <= 0) {
      // A word break: the space or / itself goes with neither piece.
      for (var i = max; i > 0; i--) {
        if (rest[i] == 0x20 || rest[i] == 0x2F) {
          cut = i;
          skip = 1;
          break;
        }
      }
    }
    if (cut <= 0) cut = max;
    final piece = str(rest.sublist(0, cut));
    if (piece.isNotEmpty) out.add(piece);
    rest = rest.sublist(cut + skip);
  }
  final last = str(rest);
  if (last.isNotEmpty) out.add(last);
  return out;
}
