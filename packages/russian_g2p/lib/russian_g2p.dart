/// Russian text, with each word's stress marked (U+0301 after the
/// stressed vowel, or a ё), to the IPA the Piper ru_RU denis voice takes.
///
/// Written from the rules of Russian pronunciation, not from espeak-ng's
/// data: a consonant is soft before е, ё, и, ю, я and ь; о and а reduce to
/// ɐ just before the stress or at the start of a word and to ə elsewhere;
/// after a soft consonant an unstressed е, я or а is ɪ; a voiced consonant
/// is voiceless at a word's end; a cluster of noisy consonants takes the
/// voicing of its last one (в voices nothing); г in -ого and -его is в.
///
/// A word with two or more vowels and no mark is one whose stress nobody
/// settled: it is said with its vowels whole and no stress, rather than
/// with a stress we guessed.
library;

export 'src/stress_table.dart';

const _acute = '́';

const _vowels = 'аеёиоуыэюя';
const _iotated = {'е': 'e', 'ё': 'o', 'ю': 'u', 'я': 'a'};
const _plainVowel = {'а': 'a', 'о': 'o', 'у': 'u', 'ы': 'ɨ', 'э': 'ɛ', 'и': 'i'};
const _softeners = 'еёиюяь';
const _alwaysHard = 'жшц';

const _hard = {
  'б': 'b', 'в': 'v', 'г': 'ɡ', 'д': 'd', 'ж': 'ʐ', 'з': 'z', 'к': 'k',
  'л': 'ɫ', 'м': 'm', 'н': 'n', 'п': 'p', 'р': 'r', 'с': 's', 'т': 't',
  'ф': 'f', 'х': 'x', 'ц': 'ts', 'ч': 'tɕ', 'ш': 'ʂ', 'щ': 'ɕː', 'й': 'j',
};
const _soft = {'л': 'l'};

const _voicedToVoiceless = {
  'b': 'p', 'v': 'f', 'ɡ': 'k', 'd': 't', 'z': 's', 'ʐ': 'ʂ',
};
final _voicelessToVoiced = {
  for (final e in _voicedToVoiceless.entries) e.value: e.key,
};
const _sonorants = {'m', 'n', 'ɫ', 'l', 'r', 'j'};

/// Short words said with no stress of their own.
const _clitics = {
  'а', 'без', 'бы', 'в', 'во', 'для', 'до', 'же', 'за', 'и', 'из', 'к',
  'ко', 'ли', 'на', 'над', 'не', 'ни', 'но', 'о', 'об', 'от', 'по', 'под',
  'при', 'про', 'с', 'со', 'у',
};

/// Words said otherwise than spelled, by spelling, stress kept.
const _respell = {
  'что': 'што', 'чтобы': 'штобы', 'конечно': 'конешно',
  'скучно': 'скушно', 'сегодня': 'севодня', 'нарочно': 'нарошно', 'яичница': 'яишница',
};

/// Words ending -ого where г is said as written.
const _keepG = {
  'много', 'немного', 'строго', 'дорого', 'недорого', 'убого', 'полого',
  'отлого', 'нагого', 'благого',
};

/// One phone: [ipa] (a consonant) or a vowel, with what the rules need.
class _Phone {
  String ipa;
  final bool vowel;
  final bool stressed;
  final String base; // vowels: a o u ɨ ɛ e i
  final bool softBefore; // vowels: after a soft consonant or j
  final bool hardHiss; // vowels: right after ж, ш or ц
  final bool first; // vowels: first sound of the word
  _Phone.consonant(this.ipa)
      : vowel = false,
        stressed = false,
        base = '',
        softBefore = false,
        hardHiss = false,
        first = false;
  _Phone.vowel(this.base,
      {required this.stressed,
      required this.softBefore,
      required this.hardHiss,
      required this.first})
      : ipa = '',
        vowel = true;
}

/// The phonemes of one word.
String wordPhonemes(String word) => _word(word, clitic: false);

String _word(String word, {required bool clitic}) {
  var w = word.toLowerCase();
  final plain = w.replaceAll(_acute, '');
  if (_respell.containsKey(plain)) {
    // Carry the mark over by vowel position.
    final marked = _markedVowel(w);
    w = _respell[plain]!;
    if (marked != null) w = _markVowel(w, marked);
  }
  w = _spellingRules(w, plain);

  // Which vowel is stressed: the marked one, else ё, else the only one.
  var stressAt = _markedVowel(w);
  final letters = w.replaceAll(_acute, '');
  final vowelCount = letters.split('').where(_vowels.contains).length;
  if (stressAt == null) {
    final yo = letters.indexOf('ё');
    if (yo >= 0) {
      stressAt = letters.substring(0, yo).split('').where(_vowels.contains).length;
    } else if (vowelCount == 1 && !clitic) {
      stressAt = 0;
    }
  }
  final reduce = stressAt != null || clitic;

  final phones = <_Phone>[];
  var vowelIndex = 0;
  for (var i = 0; i < letters.length; i++) {
    final c = letters[i];
    final prev = i > 0 ? letters[i - 1] : '';
    final next = i + 1 < letters.length ? letters[i + 1] : '';
    if (_vowels.contains(c)) {
      final afterVowelOrSign =
          i == 0 || _vowels.contains(prev) || prev == 'ъ' || prev == 'ь';
      final hardHiss = prev != '' && _alwaysHard.contains(prev);
      var softBefore = (prev != '' && 'чщй'.contains(prev)) || (prev != '' && _softeners.contains(c) && !hardHiss && !_vowels.contains(prev) && prev != 'ъ');
      String base;
      if (_iotated.containsKey(c)) {
        base = _iotated[c]!;
        if (afterVowelOrSign) {
          phones.add(_Phone.consonant('j'));
          softBefore = true;
        }
        if (hardHiss && c == 'е') base = 'ɛ';
      } else if (c == 'и' && prev == 'ь') {
        phones.add(_Phone.consonant('j'));
        base = 'i';
        softBefore = true;
      } else {
        base = _plainVowel[c]!;
        if (c == 'и' && hardHiss) base = 'ɨ';
      }
      phones.add(_Phone.vowel(base,
          stressed: stressAt == vowelIndex,
          softBefore: softBefore,
          hardHiss: hardHiss,
          first: phones.isEmpty));
      vowelIndex++;
      continue;
    }
    if (c == 'ь' || c == 'ъ') continue;
    final hard = _hard[c];
    if (hard == null) continue;
    if (next == c) continue; // a doubled consonant is said once
    final soft = next != '' &&
        _softeners.contains(next) &&
        !_alwaysHard.contains(c) &&
        !'чщй'.contains(c);
    phones.add(_Phone.consonant(soft ? '${_soft[c] ?? hard}ʲ' : hard));
  }

  _softenBeforeSoftDentals(phones);
  _voicing(phones, wordEnd: !clitic);
  for (final p in phones.where((p) => p.vowel)) {
    p.ipa = _vowelSound(p, phones, reduce);
  }
  return _withStressMark(phones);
}

String _vowelSound(_Phone p, List<_Phone> phones, bool reduce) {
  if (!reduce || p.stressed) {
    if (p.stressed && p.base == 'ɛ' && p.softBefore) return 'e';
    return p.base;
  }
  final i = phones.indexOf(p);
  final isLast = phones.lastIndexWhere((q) => q.vowel) == i;
  final next = phones.skip(i + 1).firstWhere((q) => q.vowel, orElse: () => p);
  final pretonic = next != p && next.stressed;
  switch (p.base) {
    case 'a':
    case 'o':
    case 'e':
    case 'ɛ':
      if (p.hardHiss) {
        if (p.base == 'ɛ' || p.base == 'e') return isLast ? 'ə' : 'ɨ';
        return pretonic ? 'ɐ' : 'ə';
      }
      if (p.softBefore) {
        if (isLast && p.base == 'a') return 'ə';
        return 'ɪ';
      }
      if (p.base == 'e' || p.base == 'ɛ') return 'ɪ';
      return (pretonic || p.first) ? 'ɐ' : 'ə';
    case 'u':
      return 'ʊ';
    case 'i':
      return 'ɪ';
    default:
      return p.base;
  }
}

void _softenBeforeSoftDentals(List<_Phone> phones) {
  for (var i = 0; i + 1 < phones.length; i++) {
    final p = phones[i], n = phones[i + 1];
    if (p.vowel || n.vowel) continue;
    if ((p.ipa == 's' || p.ipa == 'z') &&
        const {'tʲ', 'dʲ', 'nʲ', 'sʲ', 'zʲ'}.contains(n.ipa)) {
      p.ipa = '${p.ipa}ʲ';
    }
  }
}

String _core(String ipa) => ipa.replaceAll('ʲ', '');
String _soften(String ipa, String like) =>
    like.endsWith('ʲ') ? '$ipaʲ' : ipa;

void _voicing(List<_Phone> phones, {required bool wordEnd}) {
  // A voiced consonant at the end of the word is voiceless. A clitic
  // (в, из, под) leans on the next word, so its end is not one.
  if (wordEnd && phones.isNotEmpty && !phones.last.vowel) {
    final p = phones.last;
    final v = _voicedToVoiceless[_core(p.ipa)];
    if (v != null) p.ipa = _soften(v, p.ipa);
  }
  // Right to left: each noisy consonant takes the voicing of the next.
  for (var i = phones.length - 2; i >= 0; i--) {
    final p = phones[i], n = phones[i + 1];
    if (p.vowel || n.vowel) continue;
    final nc = _core(n.ipa);
    final pc = _core(p.ipa);
    if (nc == 'v' || _sonorants.contains(nc)) continue;
    final nextVoiced = _voicedToVoiceless.containsKey(nc);
    final nextVoiceless = _voicelessToVoiced.containsKey(nc) ||
        const {'x', 'ts', 'tɕ', 'ɕː'}.contains(nc);
    if (nextVoiced && _voicelessToVoiced.containsKey(pc)) {
      p.ipa = _soften(_voicelessToVoiced[pc]!, p.ipa);
    } else if (nextVoiceless && _voicedToVoiceless.containsKey(pc)) {
      p.ipa = _soften(_voicedToVoiceless[pc]!, p.ipa);
    }
  }
}

String _withStressMark(List<_Phone> phones) {
  final s = phones.indexWhere((p) => p.vowel && p.stressed);
  if (s < 0) return phones.map((p) => p.ipa).join();
  var onset = s;
  while (onset > 0 && !phones[onset - 1].vowel) {
    onset--;
  }
  // Inside a word, a sonorant first in a cluster closes the syllable before.
  if (onset > 0 && s - onset >= 2 && _sonorants.contains(_core(phones[onset].ipa))) {
    onset++;
  }
  final out = StringBuffer();
  for (var i = 0; i < phones.length; i++) {
    if (i == onset) out.write('ˈ');
    out.write(phones[i].ipa);
  }
  return out.toString();
}

/// Spelling-level rules, with the stress mark kept in place.
String _spellingRules(String w, String plain) {
  final m = RegExp('([ое])($_acute?)го($_acute?)\$');
  if (m.hasMatch(w) && !_keepG.contains(plain) && plain.length >= 3) {
    w = w.replaceFirstMapped(m, (x) => '${x[1]}${x[2]}во${x[3]}');
  }
  w = w.replaceAllMapped(RegExp('ть?ся\$'), (_) => 'ца');
  w = w
      .replaceAll('лнц', 'нц')
      .replaceAll('вств', 'ств')
      .replaceAll('стн', 'сн')
      .replaceAll('здн', 'зн')
      .replaceAll(RegExp('[тд]ц'), 'ц')
      .replaceAll('сч', 'щ')
      .replaceAll('зч', 'щ');
  return w;
}

int? _markedVowel(String w) {
  var n = 0;
  for (var i = 0; i < w.length; i++) {
    if (w[i] == _acute && n > 0) return n - 1;
    if (_vowels.contains(w[i])) n++;
  }
  return null;
}

String _markVowel(String w, int index) {
  var n = 0;
  for (var i = 0; i < w.length; i++) {
    if (_vowels.contains(w[i])) {
      if (n == index) return '${w.substring(0, i + 1)}$_acute${w.substring(i + 1)}';
      n++;
    }
  }
  return w;
}

const _keptPunctuation = ',.!?;:-"()';
final _token = RegExp('[А-Яа-яЁё$_acute]+|\\s+|.');

/// The phonemes of a sentence: words joined by spaces, punctuation kept.
String sentencePhonemes(String sentence) {
  final out = StringBuffer();
  for (final m in _token.allMatches(sentence)) {
    final t = m[0]!;
    if (t.trim().isEmpty) {
      out.write(' ');
    } else if (RegExp('[А-Яа-яЁё]').hasMatch(t)) {
      final plain = t.toLowerCase().replaceAll(_acute, '');
      out.write(_word(t, clitic: _clitics.contains(plain) && !t.contains(_acute)));
    } else if (_keptPunctuation.contains(t)) {
      out.write(t);
    }
  }
  return out.toString().replaceAll(RegExp(' +'), ' ').trim();
}

/// The symbols of a phoneme string, one per code point, as the voice's
/// phoneme map keys them.
List<String> phonemeSymbols(String phonemes) =>
    phonemes.runes.map(String.fromCharCode).toList();

/// The single-code-point symbols in the denis voice's phoneme map that
/// this package can produce.
const denisSymbols = {
  ' ', '!', '"', '(', ')', ',', '-', '.', ':', ';', '?', 'ˈ', 'ː', 'ʲ',
  'a', 'b', 'd', 'e', 'f', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'r',
  's', 't', 'u', 'v', 'x', 'z', 'ɐ', 'ɕ', 'ə', 'ɛ', 'ɡ', 'ɨ', 'ɪ', 'ɫ',
  'ʂ', 'ʊ', 'ʐ',
};
