/// Korean text to the phonemes the tiny Korean voice takes (owner,
/// 17 Nov 2026: a tiny voice for every language without a clean one).
///
/// Written from the standard pronunciation rules (표준 발음법), not from
/// another tool's data. Inside each word, from left to right at each
/// syllable joint:
///
///  * a final ㅎ joins a following ㄱ ㄷ ㅈ (or ㅅ) as ㅋ ㅌ ㅊ (or ㅆ), is
///    ㄴ before ㄴ, and goes before a vowel; a stop before ㅎ joins it as
///    ㅋ ㅌ ㅊ ㅍ (article 12);
///  * ㄷ and ㅌ before 이 are ㅈ and ㅊ (article 17);
///  * a final consonant moves to a following syllable that starts with a
///    vowel; of a cluster, the second moves, and a moving ㅅ from a
///    cluster is ㅆ (articles 13-14);
///  * what stays is one of seven sounds: ㄱ ㄴ ㄷ ㄹ ㅁ ㅂ ㅇ (articles 9-11);
///  * a lenis consonant after ㄱ ㄷ ㅂ is tense (article 23), and after a
///    verb-stem cluster ㄵ ㄻ ㄼ ㄾ too (articles 24-25; those clusters end
///    nothing but verb stems, save 여덟);
///  * ㄱ ㄷ ㅂ before ㄴ ㅁ are ㅇ ㄴ ㅁ; ㄹ after ㅁ ㅇ is ㄴ, and after
///    ㄱ ㅂ too, which then become nasal (articles 18-19);
///  * ㄴ next to ㄹ is ㄹ (article 20);
///  * ㅢ after a consonant is ㅣ (article 5).
///
/// Left out: rules that need to know a word's class or its parts
/// (tensing after a verb stem's ㄴ or ㅁ, 사잇소리, ㄴ insertion), and the
/// listed exceptions (밟다, 넓죽하다). Words are said one by one: nothing
/// moves across a space.
///
/// [phonemes] then spells the sounds with the aligner's labels
/// (facebook/wav2vec2-lv-60-espeak-cv-ft): a lenis stop or ㅈ is voiced
/// between voiced sounds, ㄹ is a tap at the start of a syllable and l
/// at its end or after another ㄹ, and ㅅ before ㅣ is ɕ.
///
/// Digits are not read: [spellNumbers] writes them out first.
library;

export 'src/numbers.dart';

const _initials = 'ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ';
const _medials = 'ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ';
const _finals = [
  '', 'ㄱ', 'ㄲ', 'ㄱㅅ', 'ㄴ', 'ㄴㅈ', 'ㄴㅎ', 'ㄷ', 'ㄹ', 'ㄹㄱ', 'ㄹㅁ', 'ㄹㅂ',
  'ㄹㅅ', 'ㄹㅌ', 'ㄹㅍ', 'ㄹㅎ', 'ㅁ', 'ㅂ', 'ㅂㅅ', 'ㅅ', 'ㅆ', 'ㅇ', 'ㅈ', 'ㅊ',
  'ㅋ', 'ㅌ', 'ㅍ', 'ㅎ',
];

class _Syl {
  String ini;
  String vow;

  /// The final as its consonants: '' or one or two jamo.
  String fin;
  _Syl(this.ini, this.vow, this.fin);

  String get hangul {
    final f = _finals.indexOf(fin);
    return String.fromCharCode(0xAC00 +
        (_initials.indexOf(ini) * 21 + _medials.indexOf(vow)) * 28 +
        (f < 0 ? 0 : f));
  }
}

bool _isSyllable(int c) => c >= 0xAC00 && c <= 0xD7A3;

_Syl _split(int c) {
  final i = c - 0xAC00;
  return _Syl(_initials[i ~/ 588], _medials[(i % 588) ~/ 28], _finals[i % 28]);
}

const _aspirate = {'ㄱ': 'ㅋ', 'ㄷ': 'ㅌ', 'ㅈ': 'ㅊ', 'ㅂ': 'ㅍ'};
const _tense = {'ㄱ': 'ㄲ', 'ㄷ': 'ㄸ', 'ㅂ': 'ㅃ', 'ㅅ': 'ㅆ', 'ㅈ': 'ㅉ'};
const _nasal = {'ㄱ': 'ㅇ', 'ㄷ': 'ㄴ', 'ㅂ': 'ㅁ'};

/// The one sound a final is said with.
String _neutral(String fin) => switch (fin) {
      '' => '',
      'ㄱ' || 'ㄲ' || 'ㅋ' || 'ㄱㅅ' || 'ㄹㄱ' => 'ㄱ',
      'ㄴ' || 'ㄴㅈ' || 'ㄴㅎ' => 'ㄴ',
      'ㄷ' || 'ㅅ' || 'ㅆ' || 'ㅈ' || 'ㅊ' || 'ㅌ' || 'ㅎ' => 'ㄷ',
      'ㄹ' || 'ㄹㅂ' || 'ㄹㅅ' || 'ㄹㅌ' || 'ㄹㅎ' => 'ㄹ',
      'ㅁ' || 'ㄹㅁ' => 'ㅁ',
      'ㅂ' || 'ㅍ' || 'ㅂㅅ' || 'ㄹㅍ' => 'ㅂ',
      'ㅇ' => 'ㅇ',
      _ => fin,
    };

/// A stop's sound joined with ㅎ: ㄱ ㄲ ㅋ as ㅋ, ㄷ ㅅ ㅆ ㅈ ㅊ ㅌ as ㅌ or
/// ㅊ (ㅈ ㅊ keep their place), ㅂ ㅍ as ㅍ; null for a sonorant.
String? _withH(String c) => switch (c) {
      'ㄱ' || 'ㄲ' || 'ㅋ' => 'ㅋ',
      'ㄷ' || 'ㅅ' || 'ㅆ' || 'ㅌ' => 'ㅌ',
      'ㅈ' || 'ㅊ' => 'ㅊ',
      'ㅂ' || 'ㅍ' => 'ㅍ',
      _ => null,
    };

String _last(String fin) => fin.isEmpty ? '' : fin[fin.length - 1];
String _rest(String fin) => fin.isEmpty ? '' : fin.substring(0, fin.length - 1);

void _joint(_Syl a, _Syl b) {
  // Article 12: ㅎ.
  if (_last(a.fin) == 'ㅎ') {
    final rest = _rest(a.fin);
    if (_aspirate.containsKey(b.ini) && b.ini != 'ㅂ') {
      a.fin = rest;
      b.ini = _aspirate[b.ini]!;
    } else if (b.ini == 'ㅅ') {
      a.fin = rest;
      b.ini = 'ㅆ';
    } else if (b.ini == 'ㄴ') {
      a.fin = rest.isEmpty ? 'ㄴ' : rest;
    } else if (b.ini == 'ㅇ') {
      a.fin = rest;
    }
  } else if (b.ini == 'ㅎ' && a.fin.isNotEmpty) {
    final joined = _withH(_last(a.fin));
    if (joined != null) {
      a.fin = _rest(a.fin);
      b.ini = joined;
    }
  }
  // Article 17: ㄷ ㅌ before 이. (ㄷ joined with ㅎ before 이, as in
  // 닫히다, is turned to ㅊ by [_sound], which sees the joint happen.)
  if (b.vow == 'ㅣ' &&
      b.ini == 'ㅇ' &&
      (_last(a.fin) == 'ㄷ' || _last(a.fin) == 'ㅌ')) {
    b.ini = _last(a.fin) == 'ㄷ' ? 'ㅈ' : 'ㅊ';
    a.fin = _rest(a.fin);
  }
  // Articles 13-14: a final moves to an empty onset.
  if (b.ini == 'ㅇ' && a.fin.isNotEmpty && a.fin != 'ㅇ') {
    final moving = _last(a.fin);
    final wasCluster = a.fin.length == 2;
    a.fin = _rest(a.fin);
    b.ini = wasCluster && moving == 'ㅅ' ? 'ㅆ' : moving;
    return;
  }
  final original = a.fin;
  a.fin = _neutral(a.fin);
  // Article 23, and 24-25 for the verb-stem clusters.
  if (_tense.containsKey(b.ini) &&
      (const {'ㄱ', 'ㄷ', 'ㅂ'}.contains(a.fin) ||
          const {'ㄴㅈ', 'ㄹㅁ', 'ㄹㅂ', 'ㄹㅌ'}.contains(original))) {
    b.ini = _tense[b.ini]!;
  }
  // Articles 18-19.
  if (b.ini == 'ㄹ') {
    if (const {'ㅁ', 'ㅇ'}.contains(a.fin)) {
      b.ini = 'ㄴ';
    } else if (_nasal.containsKey(a.fin)) {
      b.ini = 'ㄴ';
      a.fin = _nasal[a.fin]!;
    } else if (a.fin == 'ㄴ') {
      a.fin = 'ㄹ'; // article 20
    }
  } else if ((b.ini == 'ㄴ' || b.ini == 'ㅁ') && _nasal.containsKey(a.fin)) {
    a.fin = _nasal[a.fin]!;
  } else if (b.ini == 'ㄴ' && a.fin == 'ㄹ') {
    b.ini = 'ㄹ'; // article 20
  }
}

/// [syls] of one word, with the sound rules applied.
List<_Syl> _sound(List<_Syl> syls) {
  for (var i = 0; i + 1 < syls.length; i++) {
    final hBefore = syls[i + 1].ini == 'ㅎ' &&
        (_last(syls[i].fin) == 'ㄷ' || _last(syls[i].fin) == 'ㅅ');
    _joint(syls[i], syls[i + 1]);
    // 닫히다: ㄷ joined with ㅎ is ㅌ, and before 이 that is ㅊ.
    if (hBefore && syls[i + 1].ini == 'ㅌ' && syls[i + 1].vow == 'ㅣ') {
      syls[i + 1].ini = 'ㅊ';
    }
  }
  if (syls.isNotEmpty) syls.last.fin = _neutral(syls.last.fin);
  for (final s in syls) {
    if (s.vow == 'ㅢ' && s.ini != 'ㅇ') s.vow = 'ㅣ'; // article 5
  }
  return syls;
}

/// Runs of Hangul syllables, and everything else, in order.
Iterable<(bool, String)> _runs(String text) sync* {
  final buf = StringBuffer();
  bool? hangul;
  for (final c in text.runes) {
    final h = _isSyllable(c);
    if (hangul != null && h != hangul) {
      yield (hangul, buf.toString());
      buf.clear();
    }
    hangul = h;
    buf.writeCharCode(c);
  }
  if (hangul != null) yield (hangul, buf.toString());
}

/// [text] as it is said, written in Hangul (국물 → 궁물). Anything that
/// is not a Hangul syllable passes through.
String pronounce(String text) {
  final out = StringBuffer();
  for (final (hangul, run) in _runs(text)) {
    if (!hangul) {
      out.write(run);
      continue;
    }
    for (final s in _sound([for (final c in run.runes) _split(c)])) {
      out.write(s.hangul);
    }
  }
  return out.toString();
}

const _vowelPhones = {
  'ㅏ': ['a'], 'ㅐ': ['ɛ'], 'ㅑ': ['j', 'a'], 'ㅒ': ['j', 'ɛ'],
  'ㅓ': ['ʌ'], 'ㅔ': ['e'], 'ㅕ': ['j', 'ʌ'], 'ㅖ': ['j', 'e'],
  'ㅗ': ['o'], 'ㅘ': ['w', 'a'], 'ㅙ': ['w', 'ɛ'], 'ㅚ': ['w', 'e'],
  'ㅛ': ['j', 'o'], 'ㅜ': ['u'], 'ㅝ': ['w', 'ʌ'], 'ㅞ': ['w', 'e'],
  'ㅟ': ['w', 'i'], 'ㅠ': ['j', 'u'], 'ㅡ': ['ɯ'], 'ㅢ': ['ɯ', 'i'],
  'ㅣ': ['i'],
};

const _onsetPhone = {
  'ㄱ': 'k', 'ㄲ': 'kː', 'ㄴ': 'n', 'ㄷ': 't', 'ㄸ': 'tː', 'ㅁ': 'm',
  'ㅂ': 'p', 'ㅃ': 'pː', 'ㅅ': 's', 'ㅆ': 's̪ː', 'ㅈ': 'tɕ', 'ㅉ': 'tʃː',
  'ㅊ': 'tɕh', 'ㅋ': 'kʰ', 'ㅌ': 'tʰ', 'ㅍ': 'pʰ', 'ㅎ': 'h',
};
const _voiced = {'ㄱ': 'ɡ', 'ㄷ': 'd', 'ㅂ': 'b', 'ㅈ': 'dʑ'};
const _codaPhone = {
  'ㄱ': 'k', 'ㄴ': 'n', 'ㄷ': 't', 'ㄹ': 'l', 'ㅁ': 'm', 'ㅂ': 'p', 'ㅇ': 'ŋ',
};

/// The symbols the voice reads between words.
const punctuation = {',', '.', '?', '!'};

/// [text] as the voice's phoneme labels, with ' ' between words and the
/// marks in [punctuation] kept. Anything else that is not Hangul (digits,
/// Latin) is dropped: write numbers out first.
List<String> phonemes(String text) {
  final out = <String>[];
  void space() {
    if (out.isNotEmpty && out.last != ' ') out.add(' ');
  }

  for (final (hangul, run) in _runs(text)) {
    if (!hangul) {
      for (final c in run.split('')) {
        if (c.trim().isEmpty) {
          space();
        } else if (punctuation.contains(c)) {
          if (out.isNotEmpty && out.last == ' ') out.removeLast();
          out.add(c);
        }
      }
      continue;
    }
    final syls = _sound([for (final c in run.runes) _split(c)]);
    for (var i = 0; i < syls.length; i++) {
      final s = syls[i];
      final prevFin = i == 0 ? null : syls[i - 1].fin;
      // Voiced before: a vowel, or a sonorant final, inside the word.
      final voicedBefore = prevFin != null &&
          (prevFin.isEmpty || const {'ㄴ', 'ㄹ', 'ㅁ', 'ㅇ'}.contains(prevFin));
      final vowel = _vowelPhones[s.vow]!;
      switch (s.ini) {
        case 'ㅇ':
          break;
        case 'ㄹ':
          out.add(prevFin == 'ㄹ' ? 'l' : 'ɾ');
        case 'ㅅ' || 'ㅆ' when vowel.first == 'i' || vowel.first == 'j':
          out.add('ɕ');
        case final c when voicedBefore && _voiced.containsKey(c):
          out.add(_voiced[c]!);
        case final c:
          out.add(_onsetPhone[c]!);
      }
      out.addAll(vowel);
      if (s.fin.isNotEmpty) out.add(_codaPhone[s.fin]!);
    }
  }
  if (out.isNotEmpty && out.last == ' ') out.removeLast();
  return out;
}
