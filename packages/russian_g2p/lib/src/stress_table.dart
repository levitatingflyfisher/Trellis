/// Where the stress falls in each Russian word a table knows: the step
/// before [sentencePhonemes], which needs U+0301 after each stressed
/// vowel.
///
/// The table is a text file, one word a line: `word<TAB>vowelIndex`. The
/// word is lower case with ё written е; vowelIndex counts from 0 among
/// the vowels аеёиоуыэюя. Lines that are blank or start with `#` are
/// skipped.
///
/// About two million lines ship, so the table is never turned into two
/// million Dart strings (well over a hundred megabytes on a phone): it
/// keeps the file's bytes and an index of where each word starts and
/// ends, sorted, and looks a word up by binary search over the bytes. A
/// table already sorted by its UTF-8 bytes (`LC_ALL=C sort`) is read in
/// one pass; any other order is sorted once at load.
library;

import 'dart:convert';
import 'dart:typed_data';

const _acute = '́';
const _vowels = 'аеёиоуыэюя';
final _word = RegExp('[А-Яа-яЁё$_acute]+');

const _tab = 0x09, _lf = 0x0A, _cr = 0x0D, _hash = 0x23;
const _zero = 0x30, _nine = 0x39;

class RussianStressTable {
  final Uint8List _bytes;
  final Int32List _start;
  final Int32List _end;
  final Uint8List _vowel;

  RussianStressTable._(this._bytes, this._start, this._end, this._vowel);

  factory RussianStressTable.parse(String table) =>
      RussianStressTable.fromBytes(utf8.encode(table));

  /// [bytes] is the table file as UTF-8. A line with no tab, or with
  /// anything but digits after it, is refused with its line number.
  factory RussianStressTable.fromBytes(Uint8List bytes) {
    // Count the lines first so the index is allocated once.
    var lines = 1;
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] == _lf) lines++;
    }
    final start = Int32List(lines);
    final end = Int32List(lines);
    final vowel = Uint8List(lines);
    var n = 0;
    var sorted = true;
    var at = 0;
    var lineNo = 0;
    while (at < bytes.length) {
      lineNo++;
      var stop = at;
      while (stop < bytes.length && bytes[stop] != _lf) {
        stop++;
      }
      final next = stop + 1;
      if (stop > at && bytes[stop - 1] == _cr) stop--;
      if (stop == at || bytes[at] == _hash) {
        at = next;
        continue;
      }
      var tab = at;
      while (tab < stop && bytes[tab] != _tab) {
        tab++;
      }
      if (tab == at || tab >= stop - 1) {
        throw FormatException('stress table line $lineNo: no word<TAB>index');
      }
      var index = 0;
      for (var i = tab + 1; i < stop; i++) {
        final c = bytes[i];
        if (c < _zero || c > _nine) {
          throw FormatException(
              'stress table line $lineNo: the vowel index is not a number');
        }
        index = index * 10 + c - _zero;
        if (index > 255) {
          throw FormatException(
              'stress table line $lineNo: the vowel index is too large');
        }
      }
      start[n] = at;
      end[n] = tab;
      vowel[n] = index;
      if (sorted &&
          n > 0 &&
          _compare(bytes, start[n - 1], end[n - 1], bytes, at, tab) > 0) {
        sorted = false;
      }
      n++;
      at = next;
    }
    final s = Int32List.sublistView(start, 0, n);
    final e = Int32List.sublistView(end, 0, n);
    final v = Uint8List.sublistView(vowel, 0, n);
    if (sorted) return RussianStressTable._(bytes, s, e, v);

    final order = List<int>.generate(n, (i) => i)
      ..sort((x, y) => _compare(bytes, s[x], e[x], bytes, s[y], e[y]));
    final s2 = Int32List(n), e2 = Int32List(n), v2 = Uint8List(n);
    for (var i = 0; i < n; i++) {
      s2[i] = s[order[i]];
      e2[i] = e[order[i]];
      v2[i] = v[order[i]];
    }
    return RussianStressTable._(bytes, s2, e2, v2);
  }

  /// How many words the table knows.
  int get length => _start.length;

  /// The stressed vowel's place among [word]'s vowels, or null when the
  /// table does not know it. Any case; ё is looked up as е.
  int? vowelIndexOf(String word) {
    final key = utf8.encode(word.toLowerCase().replaceAll('ё', 'е'));
    var lo = 0, hi = _start.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final c = _compare(_bytes, _start[mid], _end[mid], key, 0, key.length);
      if (c == 0) return _vowel[mid];
      if (c < 0) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return null;
  }

  /// [sentence] with U+0301 after the stressed vowel of each word the
  /// table knows. Case is kept. A word that already has a mark or a ё,
  /// or one the table does not know, is left as it is.
  String mark(String sentence) => sentence.replaceAllMapped(_word, (m) {
        final w = m[0]!;
        if (w.contains(_acute) || w.contains('ё') || w.contains('Ё')) {
          return w;
        }
        final index = vowelIndexOf(w);
        if (index == null) return w;
        var seen = 0;
        for (var i = 0; i < w.length; i++) {
          if (_vowels.contains(w[i].toLowerCase())) {
            if (seen == index) {
              return '${w.substring(0, i + 1)}$_acute${w.substring(i + 1)}';
            }
            seen++;
          }
        }
        return w;
      });
}

/// Byte order of a[aFrom..aTo) against b[bFrom..bTo).
int _compare(List<int> a, int aFrom, int aTo, List<int> b, int bFrom, int bTo) {
  final aLen = aTo - aFrom, bLen = bTo - bFrom;
  final len = aLen < bLen ? aLen : bLen;
  for (var i = 0; i < len; i++) {
    final d = a[aFrom + i] - b[bFrom + i];
    if (d != 0) return d;
  }
  return aLen - bLen;
}
