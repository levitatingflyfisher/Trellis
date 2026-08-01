/// The lookup layer: binary search over the `.idx` entries plus reads
/// through a dictzip (or plain) body — exact, case-insensitive, and
/// prefix fallback, matching KOReader-class dictionary UX (a lookup
/// should still answer something for a near-miss typo or an inflection).
library;

import 'dart:convert';

import 'idx.dart';

enum StarDictMatchKind { exact, caseInsensitive, prefix }

class StarDictMatch {
  const StarDictMatch(this.entry, this.kind);
  final StarDictIndexEntry entry;
  final StarDictMatchKind kind;
}

/// The dictzip/plain-.dict abstraction this dictionary reads through.
/// [DictzipBody] implements it; a plain (non-gzip) `.dict` file can be
/// served by any object with a matching `read(offset, length)`.
abstract class DictBody {
  List<int> read(int offset, int length);
}

/// A plain, uncompressed `.dict` body — direct byte slicing, no
/// decompression. StarDict permits either a plain `.dict` or a `.dict.dz`;
/// this is the plain case.
class PlainDictBody implements DictBody {
  PlainDictBody(this._bytes);
  final List<int> _bytes;

  @override
  List<int> read(int offset, int length) =>
      _bytes.sublist(offset, offset + length);
}

/// Binary search over a case-insensitively SORTED view built once at
/// construction — built independently of whatever order the source
/// `.idx` file happened to be in, so lookups are correct regardless of
/// the on-disk sort convention (StarDict's spec allows more than one).
class StarDictDictionary {
  StarDictDictionary({required List<StarDictIndexEntry> entries, required this.body})
      : _sorted = List.of(entries)
          ..sort((a, b) => a.word.toLowerCase().compareTo(b.word.toLowerCase()));

  final DictBody body;
  final List<StarDictIndexEntry> _sorted;

  /// The index of the first entry whose lowercase word is `>= keyLower`.
  int _lowerBound(String keyLower) {
    var lo = 0, hi = _sorted.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_sorted[mid].word.toLowerCase().compareTo(keyLower) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Cascades exact -> case-insensitive -> prefix (first hit), matching
  /// the spec's "exact + case-insensitive + prefix fallback". Returns
  /// `null` only when nothing — not even a prefix — matches.
  StarDictMatch? lookup(String word) {
    if (word.isEmpty) return null;
    final lower = word.toLowerCase();
    final start = _lowerBound(lower);
    StarDictIndexEntry? caseInsensitiveHit;
    for (var i = start; i < _sorted.length; i++) {
      final e = _sorted[i];
      if (e.word.toLowerCase() != lower) break;
      if (e.word == word) {
        return StarDictMatch(e, StarDictMatchKind.exact);
      }
      caseInsensitiveHit ??= e;
    }
    if (caseInsensitiveHit != null) {
      return StarDictMatch(caseInsensitiveHit, StarDictMatchKind.caseInsensitive);
    }
    if (start < _sorted.length && _sorted[start].word.toLowerCase().startsWith(lower)) {
      return StarDictMatch(_sorted[start], StarDictMatchKind.prefix);
    }
    return null;
  }

  /// Every entry whose lowercase word starts with [prefix]'s lowercase
  /// form, in sorted order, up to [limit].
  List<StarDictIndexEntry> prefixMatches(String prefix, {int limit = 20}) {
    if (prefix.isEmpty) return const [];
    final lower = prefix.toLowerCase();
    final start = _lowerBound(lower);
    final out = <StarDictIndexEntry>[];
    for (var i = start; i < _sorted.length && out.length < limit; i++) {
      if (!_sorted[i].word.toLowerCase().startsWith(lower)) break;
      out.add(_sorted[i]);
    }
    return out;
  }

  /// Reads and UTF-8-decodes an entry's definition body. The `.ifo`'s
  /// `sametypesequence` (when set) means the body carries no per-entry
  /// type byte; a dictionary without it would need that byte stripped
  /// per entry — this door only serves `sametypesequence`-bearing
  /// dictionaries (the one verified registry candidate has one).
  String definitionOf(StarDictIndexEntry entry) =>
      utf8.decode(body.read(entry.offset, entry.length), allowMalformed: true);
}
