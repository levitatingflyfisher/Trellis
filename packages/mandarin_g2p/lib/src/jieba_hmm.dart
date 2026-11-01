/// jieba's two hidden Markov models and their Viterbi searches:
/// `finalseg` (word boundaries in a run the dictionary does not know:
/// states B, M, E, S) and `posseg` (boundaries and part of speech
/// together: states like `B,n`). Ported from jieba 0.42.1
/// (github.com/fxsjy/jieba, `finalseg/__init__.py`, `posseg/viterbi.py`),
/// MIT License, Copyright (c) 2013 Sun Junyi.
///
/// Ties are broken the way Python's `max` over `(prob, state)` tuples
/// breaks them: the larger state wins. Sums are added in jieba's order so
/// the doubles come out bit for bit the same.
library;

import 'dart:typed_data';

const double _minFloat = -3.14e100;
const double _minInf = double.negativeInfinity;

/// The tables of one model, parsed from the data helper's TSV: lines
/// `S state p`, `T from to p`, `E state char p`, and for posseg
/// `C char state state ...`, tab separated, after one `#` header line.
///
/// Held in typed arrays: transitions as a dense state-by-state matrix
/// (NaN where jieba's dict has no entry), emissions grouped by character
/// with each group's states sorted, so a lookup is a hash and a short
/// binary search and no boxed double is kept.
class _Tables {
  final List<String> states = [];
  final Map<String, int> index = {};
  late final Float64List start;
  late final Float64List _trans;
  late final List<Int32List> next;
  final Map<int, int> _emitGroup = {};
  late final Int32List _groupStart;
  late final Int16List _emitState;
  late final Float64List _emitProb;
  final Map<int, Int32List> charStates = {};

  int _state(String s) => index.putIfAbsent(s, () {
        states.add(s);
        return states.length - 1;
      });

  _Tables.parse(String text) {
    final startRows = <(int, double)>[];
    final transRows = <(int, int, double)>[];
    final emitChar = <int>[];
    final emitSt = <int>[];
    final emitP = <double>[];
    final charRows = <(int, List<String>)>[];
    for (final raw in text.split('\n')) {
      final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
      if (line.isEmpty || line.startsWith('#')) continue;
      final f = line.split('\t');
      switch (f[0]) {
        case 'S':
          startRows.add((_state(f[1]), double.parse(f[2])));
        case 'T':
          transRows.add((_state(f[1]), _state(f[2]), double.parse(f[3])));
        case 'E':
          final r = f[2].runes;
          if (r.length != 1) {
            throw FormatException('emission char is not one character', line);
          }
          emitChar.add(r.first);
          emitSt.add(_state(f[1]));
          emitP.add(double.parse(f[3]));
        case 'C':
          charRows.add((f[1].runes.first, f[2].split(' ')));
        default:
          throw FormatException('unknown HMM line', line);
      }
    }
    for (final (c, list) in charRows) {
      charStates[c] = Int32List.fromList([
        for (final s in list)
          if (s.isNotEmpty) _state(s)
      ]);
    }
    final n = states.length;
    start = Float64List(n)..fillRange(0, n, _minFloat);
    for (final (y, p) in startRows) {
      start[y] = p;
    }
    _trans = Float64List(n * n)..fillRange(0, n * n, double.nan);
    final nexts = List<List<int>>.generate(n, (_) => <int>[]);
    for (final (a, b, p) in transRows) {
      if (_trans[a * n + b].isNaN) nexts[a].add(b);
      _trans[a * n + b] = p;
    }
    next = [for (final l in nexts) Int32List.fromList(l)];
    // Emissions: sort by (char, state); a later line for the same pair
    // wins, as in a Python dict.
    final order = List<int>.generate(emitChar.length, (i) => i)
      ..sort((a, b) {
        final c = emitChar[a] - emitChar[b];
        if (c != 0) return c;
        final s = emitSt[a] - emitSt[b];
        return s != 0 ? s : a - b;
      });
    final keep = <int>[];
    for (var k = 0; k < order.length; k++) {
      if (k + 1 < order.length &&
          emitChar[order[k]] == emitChar[order[k + 1]] &&
          emitSt[order[k]] == emitSt[order[k + 1]]) {
        continue;
      }
      keep.add(order[k]);
    }
    _emitState = Int16List(keep.length);
    _emitProb = Float64List(keep.length);
    final groups = <int>[];
    for (var k = 0; k < keep.length; k++) {
      final i = keep[k];
      if (k == 0 || emitChar[i] != emitChar[keep[k - 1]]) {
        _emitGroup[emitChar[i]] = groups.length;
        groups.add(k);
      }
      _emitState[k] = emitSt[i];
      _emitProb[k] = emitP[i];
    }
    groups.add(keep.length);
    _groupStart = Int32List.fromList(groups);
  }

  /// `emit_p[y].get(c, missing)`.
  double emit(int y, int c, double missing) {
    final g = _emitGroup[c];
    if (g == null) return missing;
    var lo = _groupStart[g];
    var hi = _groupStart[g + 1] - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final s = _emitState[mid];
      if (s < y) {
        lo = mid + 1;
      } else if (s > y) {
        hi = mid - 1;
      } else {
        return _emitProb[mid];
      }
    }
    return missing;
  }

  /// `trans_p[a].get(b, missing)`.
  double trans(int a, int b, double missing) {
    final t = _trans[a * states.length + b];
    return t.isNaN ? missing : t;
  }
}

/// `jieba.finalseg`: cuts a run of Chinese characters the dictionary did
/// not cover into words.
class FinalsegHmm {
  FinalsegHmm.parse(String text) : _t = _Tables.parse(text) {
    for (final s in const ['B', 'M', 'E', 'S']) {
      if (!_t.index.containsKey(s)) {
        throw FormatException('finalseg table lacks state $s');
      }
    }
    _b = _t.index['B']!;
    _m = _t.index['M']!;
    _e = _t.index['E']!;
    _s = _t.index['S']!;
  }

  final _Tables _t;
  late final int _b, _m, _e, _s;

  /// finalseg's private `__cut` over one run of Han characters (code
  /// points).
  List<String> cutHan(List<int> obs) {
    final states = [_b, _m, _e, _s];
    // PrevStatus, and the state's letter for tie-breaks.
    final prev = <int, List<int>>{
      _b: [_e, _s],
      _m: [_m, _b],
      _s: [_s, _e],
      _e: [_b, _m],
    };
    final letter = <int, int>{_b: 0x42, _m: 0x4D, _e: 0x45, _s: 0x53};
    var v = <int, double>{};
    var path = <int, List<int>>{};
    for (final y in states) {
      v[y] = _t.start[y] + _t.emit(y, obs[0], _minFloat);
      path[y] = [y];
    }
    for (var t = 1; t < obs.length; t++) {
      final nv = <int, double>{};
      final np = <int, List<int>>{};
      for (final y in states) {
        final em = _t.emit(y, obs[t], _minFloat);
        double? best;
        var bestState = -1;
        for (final y0 in prev[y]!) {
          final p = v[y0]! + _t.trans(y0, y, _minFloat) + em;
          if (best == null ||
              p > best ||
              (p == best && letter[y0]! > letter[bestState]!)) {
            best = p;
            bestState = y0;
          }
        }
        nv[y] = best!;
        np[y] = [...path[bestState]!, y];
      }
      v = nv;
      path = np;
    }
    // max((V[-1][y], y) for y in 'ES')
    final pe = v[_e]!;
    final ps = v[_s]!;
    final last = (ps > pe || ps == pe) ? _s : _e;
    final pos = path[last]!;
    final out = <String>[];
    var begin = 0;
    var nexti = 0;
    for (var i = 0; i < obs.length; i++) {
      final p = pos[i];
      if (p == _b) {
        begin = i;
      } else if (p == _e) {
        out.add(String.fromCharCodes(obs, begin, i + 1));
        nexti = i + 1;
      } else if (p == _s) {
        out.add(String.fromCharCode(obs[i]));
        nexti = i + 1;
      }
    }
    if (nexti < obs.length) out.add(String.fromCharCodes(obs, nexti));
    return out;
  }
}

/// `jieba.posseg`'s model: cuts a run of Han characters into words and
/// tags each.
class PossegHmm {
  PossegHmm.parse(String text) : _t = _Tables.parse(text) {
    final n = _t.states.length;
    _pos = List<String>.generate(n, (i) => _t.states[i].split(',')[0]);
    _tag = List<String>.generate(n, (i) {
      final s = _t.states[i];
      return s.substring(s.indexOf(',') + 1);
    });
    // Python compares the state tuples (position, tag) lexicographically.
    final order = List<int>.generate(n, (i) => i)
      ..sort((a, b) {
        final c = _cmp(_pos[a], _pos[b]);
        return c != 0 ? c : _cmp(_tag[a], _tag[b]);
      });
    _rank = Int32List(n);
    for (var r = 0; r < n; r++) {
      _rank[order[r]] = r;
    }
    _all = List<int>.generate(n, (i) => i);
    _hasNext = [for (final m in _t.next) m.isNotEmpty];
  }

  final _Tables _t;
  late final List<String> _pos;
  late final List<String> _tag;
  late final Int32List _rank;
  late final List<int> _all;
  late final List<bool> _hasNext;

  static int _cmp(String a, String b) {
    final ra = a.runes.toList();
    final rb = b.runes.toList();
    for (var i = 0; i < ra.length && i < rb.length; i++) {
      if (ra[i] != rb[i]) return ra[i] - rb[i];
    }
    return ra.length - rb.length;
  }

  bool _better(double p, int s, double best, int bestState) =>
      p > best || (p == best && _rank[s] > _rank[bestState]);

  /// posseg's private `__cut`: the Viterbi path over [obs] (code points),
  /// grouped into (word, tag) pairs.
  List<(String, String)> cutHan(List<int> obs) {
    final n = obs.length;
    final vs = <Map<int, double>>[];
    final mem = <Map<int, int>>[];
    final v0 = <int, double>{};
    final m0 = <int, int>{};
    for (final y in _t.charStates[obs[0]] ?? _all) {
      v0[y] = _t.start[y] + _t.emit(y, obs[0], _minFloat);
      m0[y] = -1;
    }
    vs.add(v0);
    mem.add(m0);
    for (var t = 1; t < n; t++) {
      final prevStates = [
        for (final x in mem[t - 1].keys)
          if (_hasNext[x]) x
      ];
      final expectNext = <int>{
        for (final x in prevStates) ..._t.next[x],
      };
      var obsStates =
          (_t.charStates[obs[t]] ?? _all).toSet().intersection(expectNext);
      if (obsStates.isEmpty) {
        obsStates = expectNext.isNotEmpty ? expectNext : _all.toSet();
      }
      final vt = <int, double>{};
      final mt = <int, int>{};
      final prevV = vs[t - 1];
      for (final y in obsStates) {
        final em = _t.emit(y, obs[t], _minFloat);
        double? best;
        var bestState = -1;
        for (final y0 in prevStates) {
          final p = prevV[y0]! + _t.trans(y0, y, _minInf) + em;
          if (best == null || _better(p, y0, best, bestState)) {
            best = p;
            bestState = y0;
          }
        }
        if (best == null) throw StateError('posseg viterbi: no previous state');
        vt[y] = best;
        mt[y] = bestState;
      }
      vs.add(vt);
      mem.add(mt);
    }
    double? best;
    var state = -1;
    for (final e in vs.last.entries) {
      if (best == null || _better(e.value, e.key, best, state)) {
        best = e.value;
        state = e.key;
      }
    }
    final route = List<int>.filled(n, 0);
    for (var i = n - 1; i >= 0; i--) {
      route[i] = state;
      state = mem[i][state]!;
    }
    final out = <(String, String)>[];
    var begin = 0;
    var nexti = 0;
    for (var i = 0; i < n; i++) {
      final pos = _pos[route[i]];
      if (pos == 'B') {
        begin = i;
      } else if (pos == 'E') {
        out.add((String.fromCharCodes(obs, begin, i + 1), _tag[route[i]]));
        nexti = i + 1;
      } else if (pos == 'S') {
        out.add((String.fromCharCode(obs[i]), _tag[route[i]]));
        nexti = i + 1;
      }
    }
    if (nexti < n) {
      out.add((String.fromCharCodes(obs, nexti), _tag[route[nexti]]));
    }
    return out;
  }
}
