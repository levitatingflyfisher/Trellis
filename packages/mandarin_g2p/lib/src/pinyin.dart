/// The parts of pypinyin that misaki uses: `lazy_pinyin(word,
/// style=Style.INITIALS or Style.FINALS_TONE3, strict=True,
/// neutral_tone_with_five=True)` over the default converter, with the
/// default segmenter (split Han from non-Han, then greedy longest match
/// against the phrase table). Ported from pypinyin 0.55.0
/// (github.com/mozillazg/python-pinyin: `core.py`, `converter.py`,
/// `seg/simpleseg.py`, `seg/mmseg.py`, `standard.py`, `style/_utils.py`,
/// `style/_tone_convert.py`, `contrib/neutral_tone.py`), MIT License,
/// Copyright (c) 2016 mozillazg, 闲耘.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'py_text.dart';
import 'sorted_words.dart';

/// pypinyin's dictionaries, after misaki's own overrides are loaded.
class PinyinTables {
  PinyinTables._(
      this._syllables,
      this._singleCode,
      this._singleSyl,
      this._phrases,
      this._phraseStart,
      this._phraseSyl,
      this._symbols,
      this._initials,
      this._initialsNotStrict,
      this._finals);

  /// [single]: `pypinyin_single.tsv` (hex code point, tab, readings with
  /// tone marks, comma separated). [phrases]: `pypinyin_phrases.tsv`
  /// (word, tab, syllables separated by spaces, alternatives by commas).
  /// [aux]: `pypinyin_aux.json` (phonetic symbols, initials, finals).
  /// [singleOverride] and [phrasesOverride] are loaded on top, as
  /// misaki's `load_single_dict` and `load_phrases_dict` calls do.
  ///
  /// Only the first reading of each character and syllable is kept: with
  /// heteronyms off, pypinyin never reads the others. Readings are stored
  /// once each and referred to by number.
  factory PinyinTables.parse({
    required String single,
    required String phrases,
    required String aux,
    Map<String, String> singleOverride = const {},
    Map<String, List<List<String>>> phrasesOverride = const {},
  }) {
    final syllables = <String>[];
    final sylIndex = <String, int>{};
    int syl(String s) => sylIndex.putIfAbsent(s, () {
          syllables.add(s);
          return syllables.length - 1;
        });
    final s = <int, int>{};
    for (final f in _rows(single)) {
      s[int.parse(f[0], radix: 16)] = syl(f[1].split(',')[0]);
    }
    for (final e in singleOverride.entries) {
      s[e.key.runes.single] = syl(e.value.split(',')[0]);
    }
    final codes = s.keys.toList()..sort();
    final singleCode = Int32List.fromList(codes);
    final singleSyl = Uint16List.fromList([for (final c in codes) s[c]!]);

    final words = <String>[];
    final readings = <List<int>>[];
    for (final f in _rows(phrases)) {
      words.add(f[0]);
      readings.add([for (final x in f[1].split(' ')) syl(x.split(',')[0])]);
    }
    for (final e in phrasesOverride.entries) {
      words.add(e.key);
      readings.add([for (final x in e.value) syl(x[0])]);
    }
    if (syllables.length > 0xFFFF) throw const FormatException('syllables');
    final (table, source) = SortedWords.build(words);
    final start = Int32List(table.length + 1);
    final flat = <int>[];
    for (var w = 0; w < table.length; w++) {
      start[w] = flat.length;
      flat.addAll(readings[source[w]]);
    }
    start[table.length] = flat.length;

    final a = jsonDecode(aux) as Map<String, dynamic>;
    final symbols = (a['phonetic_symbol'] as Map<String, dynamic>)
        .map((k, v) => MapEntry(k, v as String));
    return PinyinTables._(
      syllables,
      singleCode,
      singleSyl,
      table,
      start,
      Uint16List.fromList(flat),
      symbols,
      (a['initials'] as List).cast<String>(),
      (a['initials_not_strict'] as List).cast<String>(),
      (a['finals'] as List).cast<String>().toSet(),
    );
  }

  final List<String> _syllables;
  final Int32List _singleCode;
  final Uint16List _singleSyl;
  final SortedWords _phrases;
  final Int32List _phraseStart;
  final Uint16List _phraseSyl;

  /// `PINYIN_DICT[ord(c)]`'s first reading, or null.
  String? _singleOf(int c) {
    var lo = 0;
    var hi = _singleCode.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final v = _singleCode[mid];
      if (v < c) {
        lo = mid + 1;
      } else if (v > c) {
        hi = mid - 1;
      } else {
        return _syllables[_singleSyl[mid]];
      }
    }
    return null;
  }

  /// `PHRASES_DICT[word]`'s first readings, or null.
  List<String>? _phraseOf(String word) {
    final w = _phrases.indexOf(word);
    if (w < 0) return null;
    return [
      for (var i = _phraseStart[w]; i < _phraseStart[w + 1]; i++)
        _syllables[_phraseSyl[i]]
    ];
  }

  /// `word in prefix_set`: [word] starts some phrase (or is one).
  bool _isPrefix(String word) {
    var lo = 0;
    var hi = _phrases.length;
    for (var d = 0; d < word.length && lo < hi; d++) {
      (lo, hi) = _phrases.narrow(lo, hi, d, word.codeUnitAt(d));
    }
    return lo < hi;
  }

  final Map<String, String> _symbols;
  final List<String> _initials;
  final List<String> _initialsNotStrict;
  final Set<String> _finals;

  static Iterable<List<String>> _rows(String text) sync* {
    for (var line in const LineSplitter().convert(text)) {
      if (line.isEmpty || line.startsWith('#')) continue;
      final tab = line.indexOf('\t');
      yield [line.substring(0, tab), line.substring(tab + 1)];
    }
  }

  /// `lazy_pinyin(word, style=Style.INITIALS, ...)`.
  List<String> initials(String word) => _lazy(word, toInitials);

  /// `lazy_pinyin(word, style=Style.FINALS_TONE3,
  /// neutral_tone_with_five=True)`.
  List<String> finalsTone3(String word) => _lazy(word, (p) {
        final f = toFinalsTone3(p);
        // NeutralToneWith5Mixin.post_convert_style
        if (f.isEmpty) return f;
        if (_hasDigit(f)) return f;
        return '${f}5';
      });

  List<String> _lazy(String word, String Function(String) style) {
    final out = <String>[];
    for (final (piece, han) in _simpleSeg(word)) {
      if (!han) {
        // handle_nopinyin with errors='default': the run as it is.
        out.add(piece);
        continue;
      }
      for (final w in _mmseg(piece)) {
        final ph = _phraseOf(w);
        if (ph != null) {
          // convert_styles walks the phrase's characters by index.
          final n = pyLen(w);
          if (ph.length > n) {
            throw RangeError('phrase $w has more syllables than characters');
          }
          for (final raw in ph) {
            out.add(style(raw));
          }
        } else {
          for (final c in w.runes) {
            // A character with no reading goes through the style as
            // itself, which yields ''.
            final raw = _singleOf(c) ?? String.fromCharCode(c);
            out.add(style(raw));
          }
        }
      }
    }
    return out;
  }

  /// simpleseg's `_seg`: runs of Han and non-Han characters.
  static List<(String, bool)> _simpleSeg(String s) {
    final out = <(String, bool)>[];
    final r = s.runes.toList();
    var i = 0;
    while (i < r.length) {
      final h = isHans(r[i]);
      var j = i + 1;
      while (j < r.length && isHans(r[j]) == h) {
        j++;
      }
      out.add((String.fromCharCodes(r, i, j), h));
      i = j;
    }
    return out;
  }

  /// mmseg's `Seg.cut` with `no_non_phrases=True`.
  List<String> _mmseg(String text) {
    final out = <String>[];
    var remain = text.runes.toList();
    while (remain.isNotEmpty) {
      var lastValid = '';
      var lastValidIndex = 0;
      var broke = false;
      for (var index = 0; index < remain.length; index++) {
        final word = String.fromCharCodes(remain, 0, index + 1);
        if (_isPrefix(word)) {
          if (_phrases.indexOf(word) >= 0) {
            lastValid = word;
            lastValidIndex = index + 1;
          }
        } else {
          if (lastValid.isNotEmpty) {
            out.add(lastValid);
            remain = remain.sublist(lastValidIndex);
          } else {
            out.add(String.fromCharCode(remain[0]));
            remain = remain.sublist(1);
          }
          broke = true;
          break;
        }
      }
      if (broke) continue;
      if (lastValid.isNotEmpty) {
        out.add(lastValid);
        remain = remain.sublist(lastValidIndex);
      } else {
        final rest = String.fromCharCodes(remain);
        if (_phrases.indexOf(rest) < 0) {
          for (final c in remain) {
            out.add(String.fromCharCode(c));
          }
        } else {
          out.add(rest);
        }
        break;
      }
    }
    return out;
  }

  // ---- style functions -------------------------------------------------

  /// `get_initials(pinyin, strict=True)`.
  String toInitials(String pinyin) {
    for (final i in _initials) {
      if (pinyin.startsWith(i)) return i;
    }
    return '';
  }

  String _initialsLoose(String pinyin) {
    for (final i in _initialsNotStrict) {
      if (pinyin.startsWith(i)) return i;
    }
    return '';
  }

  /// `to_finals_tone3(pinyin, strict=True)` (without the neutral-tone
  /// mixin).
  String toFinalsTone3(String pinyin) {
    pinyin = pinyin.replaceAll('5', '');
    final finals = _toFinals(pinyin);
    if (finals.isEmpty) return finals;
    final numbers = _digits(_symbolToNumber(pinyin));
    if (numbers.isEmpty) return finals;
    return finals + numbers.first;
  }

  String _toFinals(String pinyin) {
    final p = _symbolToNoSymbol(pinyin).replaceAll('v', 'ü');
    return _getFinals(p).replaceAll('ü', 'v');
  }

  String _getFinals(String pinyin) {
    pinyin = _convertFinals(pinyin);
    final ini = toInitials(pinyin);
    var finals = pinyin.substring(ini.length);
    if (!_finals.contains(finals)) {
      final ini2 = _initialsLoose(pinyin);
      finals = pinyin.substring(ini2.length);
      return _finals.contains(finals) ? finals : '';
    }
    return finals;
  }

  String _symbolToNumber(String pinyin) {
    final b = StringBuffer();
    for (final c in pinyin.runes) {
      final ch = String.fromCharCode(c);
      final to = _symbols[ch];
      b.write(to ?? ch);
    }
    var value = b.toString();
    for (final e in _symbols.entries) {
      if (e.key.runes.length > 1) value = value.replaceAll(e.key, e.value);
    }
    return value;
  }

  String _symbolToNoSymbol(String pinyin) {
    final s = _symbolToNumber(pinyin);
    final b = StringBuffer();
    for (final c in s.runes) {
      if (!pyIsDecimal(c)) b.writeCharCode(c);
    }
    return b.toString();
  }

  static List<String> _digits(String s) => [
        for (final c in s.runes)
          if (pyIsDecimal(c)) String.fromCharCode(c)
      ];

  static bool _hasDigit(String s) => s.runes.any(pyIsDecimal);

  // ---- standard.py: strict finals --------------------------------------

  static const _uv = {'u': 'ü', 'ū': 'ǖ', 'ú': 'ǘ', 'ǔ': 'ǚ', 'ù': 'ǜ'};
  static const _iTones = {'i', 'ī', 'í', 'ǐ', 'ì'};
  static const _iu = {
    'iu': 'iou', 'iū': 'ioū', 'iú': 'ioú', 'iǔ': 'ioǔ', 'iù': 'ioù', //
  };
  static const _ui = {
    'ui': 'uei', 'uī': 'ueī', 'uí': 'ueí', 'uǐ': 'ueǐ', 'uì': 'ueì', //
  };
  static const _un = {
    'un': 'uen', 'ūn': 'ūen', 'ún': 'úen', 'ǔn': 'ǔen', 'ùn': 'ùen', //
  };
  static final _uvRe = RegExp('^(j|q|x)(${_uv.keys.join('|')})(.*)\$');
  static final _iuRe = RegExp('^([a-z]+)(${_iu.keys.join('|')})\$');
  static final _uiRe = RegExp('([a-z]+)(${_ui.keys.join('|')})\$');
  static final _unRe = RegExp('([a-z]+)(${_un.keys.join('|')})\$');

  String _convertZeroConsonant(String pinyin) {
    final raw = pinyin;
    if (raw.startsWith('y')) {
      final noY = pyChars(pinyin).sublist(1);
      final first = noY.isNotEmpty ? noY[0] : null;
      if (first != null && _uv.containsKey(first)) {
        pinyin = _uv[first]! + pyChars(pinyin).sublist(2).join();
      } else if (first != null && _iTones.contains(first)) {
        pinyin = noY.join();
      } else {
        pinyin = 'i${noY.join()}';
      }
    }
    if (raw.startsWith('w')) {
      final noW = pyChars(pinyin).sublist(1);
      final first = noW.isNotEmpty ? noW[0] : null;
      if (first != null && _uv.containsKey(first)) {
        pinyin = noW.join();
      } else {
        pinyin = 'u${noW.join()}';
      }
    }
    if (!_finals.contains(pinyin)) return raw;
    return pinyin;
  }

  String _convertFinals(String pinyin) {
    pinyin = _convertZeroConsonant(pinyin);
    pinyin =
        pinyin.replaceFirstMapped(_uvRe, (m) => '${m[1]}${_uv[m[2]]}${m[3]}');
    pinyin = pinyin.replaceFirstMapped(_iuRe, (m) => '${m[1]}${_iu[m[2]]}');
    pinyin = pinyin.replaceFirstMapped(_uiRe, (m) => '${m[1]}${_ui[m[2]]}');
    pinyin = pinyin.replaceFirstMapped(_unRe, (m) => '${m[1]}${_un[m[2]]}');
    return pinyin;
  }
}

/// pypinyin's RE_HANS for one code point (the wide-build ranges).
bool isHans(int c) =>
    c == 0x3007 ||
    (c >= 0xE815 && c <= 0xE864) ||
    c == 0xFA18 ||
    (c >= 0x3400 && c <= 0x4DBF) ||
    (c >= 0x4E00 && c <= 0x9FFF) ||
    (c >= 0xF900 && c <= 0xFAFF) ||
    (c >= 0x20000 && c <= 0x2A6DF) ||
    (c >= 0x2A703 && c <= 0x2B73F) ||
    (c >= 0x2B740 && c <= 0x2B81D) ||
    (c >= 0x2B825 && c <= 0x2BF6E) ||
    (c >= 0x2C029 && c <= 0x2CE93) ||
    c == 0x2D016 ||
    (c >= 0x2D11B && c <= 0x2EBD9) ||
    (c >= 0x2F80A && c <= 0x2FA1F) ||
    (c >= 0x30000 && c <= 0x3134A) ||
    (c >= 0x300F7 && c <= 0x31288) ||
    c == 0x30EDD ||
    c == 0x30EDE ||
    (c >= 0x31350 && c <= 0x32389);
