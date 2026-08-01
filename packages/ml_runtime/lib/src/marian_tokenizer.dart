/// A pure-Dart SentencePiece unigram tokenizer for the Marian (opus-mt)
/// translation models (ADR-0008 "Babel"): a hand-rolled protobuf reader
/// for exactly the fields a `.spm` model file's piece table needs, a
/// Viterbi unigram encoder over that table, and the joint-vocabulary
/// piece<->id mapping `vocab.json` carries (Marian's `separate_vocabs:
/// false` — one id space shared by both languages).
///
/// Deliberately narrow scope, recorded here so a future reader does not
/// mistake the gaps for bugs:
///  * Normalization implements exactly what `source.spm`'s real
///    `nmt_nfkc` normalizer does for NFKC-STABLE input — whitespace-run
///    collapse, trim, a dummy leading space, and escaping every space to
///    ▁ (U+2581) — verified byte-for-byte against the real model's own
///    `.normalize()` for 24 diverse sentences (ADR-0008). It does NOT
///    port the 237KB precompiled NFKC charsmap, so genuinely
///    NFKC-unstable input (decomposed combining characters, full-width
///    forms, compatibility ligatures) can tokenize differently than the
///    real model. One golden vector documents this gap on purpose.
///  * The protobuf reader parses only `ModelProto.pieces` (top-level
///    field 1) and, within each `SentencePiece`, only `piece` (field 1),
///    `score` (field 2) and `type` (field 3) — every other field
///    (`trainer_spec`, `normalizer_spec` and its 237KB charsmap, etc.)
///    is skipped by wire type, never decoded. No proto library.
library;

import 'dart:convert';
import 'dart:typed_data';

// ---------------------------------------------------------------------
// The protobuf reader — just enough wire format to read repeated
// SentencePiece{piece, score, type} out of a .spm ModelProto.
// ---------------------------------------------------------------------

/// A `SentencePiece.type` value (the ModelProto enum) — only the values
/// that occur in a Marian `.spm` file's piece table are named; anything
/// else (`unused`, `byte`) parses to [SpmPieceType.other] rather than
/// throwing, since a future model revision naming a new type must not
/// crash a working tokenizer over a piece this encoder never needed to
/// match.
enum SpmPieceType {
  normal,
  unknown,
  control,
  userDefined,
  other;

  static SpmPieceType fromWireValue(int v) => switch (v) {
        1 => SpmPieceType.normal,
        2 => SpmPieceType.unknown,
        3 => SpmPieceType.control,
        4 => SpmPieceType.userDefined,
        _ => SpmPieceType.other,
      };
}

/// One row of a `.spm` model's piece table.
class SpmPiece {
  final String piece;
  final double score;
  final SpmPieceType type;

  const SpmPiece(this.piece, this.score, [this.type = SpmPieceType.normal]);
}

class _ProtoCursor {
  final Uint8List bytes;
  int pos = 0;
  _ProtoCursor(this.bytes);

  bool get atEnd => pos >= bytes.length;

  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final b = bytes[pos++];
      result |= (b & 0x7f) << shift;
      if (b & 0x80 == 0) return result;
      shift += 7;
    }
  }

  Uint8List readLengthDelimited() {
    final len = readVarint();
    final out = Uint8List.sublistView(bytes, pos, pos + len);
    pos += len;
    return out;
  }

  double readFixed32Float() {
    final view = ByteData.sublistView(bytes, pos, pos + 4);
    pos += 4;
    return view.getFloat32(0, Endian.little);
  }

  /// Skips one field's value per its wire type — the mechanism that lets
  /// this reader ignore every field it does not name, forever.
  void skipValue(int wireType) {
    switch (wireType) {
      case 0: // varint
        readVarint();
      case 1: // 64-bit fixed
        pos += 8;
      case 2: // length-delimited
        // NOT `pos += readVarint();` — Dart evaluates the `+=` target's
        // OLD value before the call, so it would add the payload length
        // to the position from BEFORE readVarint() advanced past the
        // length varint's own bytes, silently under-skipping by however
        // many bytes that varint occupied (2 bytes short on this exact
        // file, verified against a real .spm: it landed inside the
        // trailing bytes of `normalizer_spec`'s payload and then read
        // garbage as the next field key). Two statements, in order.
        final len = readVarint();
        pos += len;
      case 5: // 32-bit fixed
        pos += 4;
      default:
        throw FormatException('parseSpmPieceTable: unsupported wire type '
            '$wireType at byte $pos — not a SentencePiece ModelProto?');
    }
  }
}

SpmPiece _parseSentencePiece(Uint8List bytes) {
  final c = _ProtoCursor(bytes);
  String piece = '';
  double score = 0.0;
  SpmPieceType type = SpmPieceType.normal;
  while (!c.atEnd) {
    final key = c.readVarint();
    final fieldNumber = key >> 3;
    final wireType = key & 0x7;
    switch (fieldNumber) {
      case 1:
        piece = utf8.decode(c.readLengthDelimited());
      case 2:
        score = c.readFixed32Float();
      case 3:
        type = SpmPieceType.fromWireValue(c.readVarint());
      default:
        c.skipValue(wireType);
    }
  }
  return SpmPiece(piece, score, type);
}

/// Parses a `.spm` model file's byte content into its piece table
/// (`ModelProto.pieces`, top-level field 1) — every other top-level field
/// (`trainer_spec`, `normalizer_spec`, ...) is skipped, never decoded.
List<SpmPiece> parseSpmPieceTable(Uint8List bytes) {
  final c = _ProtoCursor(bytes);
  final pieces = <SpmPiece>[];
  while (!c.atEnd) {
    final key = c.readVarint();
    final fieldNumber = key >> 3;
    final wireType = key & 0x7;
    if (fieldNumber == 1 && wireType == 2) {
      pieces.add(_parseSentencePiece(c.readLengthDelimited()));
    } else {
      c.skipValue(wireType);
    }
  }
  return pieces;
}

// ---------------------------------------------------------------------
// The Viterbi unigram encoder.
// ---------------------------------------------------------------------

const String _spaceEscape = '▁'; // ▁

/// Folds Unicode's Halfwidth-and-Fullwidth-Forms punctuation block
/// (U+FF01-U+FF5E — the fullwidth '！'/'？'/etc. every CJK IME emits) to
/// its plain-ASCII counterpart (U+0021-U+007E), a fixed `-0xFEE0`
/// codepoint offset. Verified against real sentencepiece output from the
/// zh-en/jap-en `source.spm` models (Campaign 8 "Babel widens" Phase 0,
/// docs/reference/mt-models.md): this is the ONE cause of every observed
/// divergence on real CJK golden sentences, and it is common in ordinary
/// text (not a rare edge case the way a decomposed Latin accent is) —
/// worth porting exactly even though the general 237KB NFKC charsmap
/// stays out of scope. Deliberately does NOT touch ideographic
/// punctuation (U+3001 、, U+3002 。) or the ideographic space (U+3000):
/// the real model's normalizer leaves those alone, confirmed on the same
/// golden sentences.
String _foldFullwidthAscii(String text) {
  final out = StringBuffer();
  for (final codePoint in text.runes) {
    if (codePoint >= 0xFF01 && codePoint <= 0xFF5E) {
      out.writeCharCode(codePoint - 0xFEE0);
    } else {
      out.writeCharCode(codePoint);
    }
  }
  return out.toString();
}

class MarianUnigramTokenizer {
  final Map<String, double> _scoreByPiece;
  late final double _unkFallbackScore;

  MarianUnigramTokenizer(List<SpmPiece> pieces)
      : _scoreByPiece = {
          for (final p in pieces)
            if (p.type == SpmPieceType.normal) p.piece: p.score,
        } {
    // Always dispreferred to any real piece, so a genuine vocabulary hit
    // never loses to the fallback — but still finite, so it always lets
    // the Viterbi search make progress through genuinely uncovered text.
    final scores = _scoreByPiece.values;
    final minScore =
        scores.isEmpty ? 0.0 : scores.reduce((a, b) => a < b ? a : b);
    _unkFallbackScore = minScore - 10.0;
  }

  /// Fullwidth-to-halfwidth folding + whitespace-collapse + trim +
  /// dummy-prefix + ▁-escape — verified against `source.spm`'s real
  /// normalizer for NFKC-stable input; see the library doc comment for
  /// what is and is not covered.
  static String normalize(String text) {
    final folded = _foldFullwidthAscii(text);
    final collapsed = folded.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.isEmpty) return '';
    return ('$_spaceEscape$collapsed').replaceAll(' ', _spaceEscape);
  }

  /// Viterbi-segments [text] (after [normalize]) into the highest-total
  /// -score sequence of known pieces. Codepoints no known piece covers
  /// fall back to raw single-codepoint spans; consecutive fallback spans
  /// merge into one piece, matching real sentencepiece's unknown-run
  /// merging (verified empirically against source.spm — see ADR-0008).
  List<String> encodeToPieces(String text) {
    final normalized = normalize(text);
    if (normalized.isEmpty) return [];
    final cps = normalized.runes.toList();
    final n = cps.length;

    final dp = List<double>.filled(n + 1, double.negativeInfinity);
    final back = List<int>.filled(n + 1, -1);
    dp[0] = 0.0;

    for (var end = 1; end <= n; end++) {
      for (var start = 0; start < end; start++) {
        if (dp[start] == double.negativeInfinity) continue;
        final candidate = String.fromCharCodes(cps, start, end);
        final knownScore = _scoreByPiece[candidate];
        // A real vocabulary hit always applies; the single-codepoint
        // fallback edge is only offered when this exact span is one
        // codepoint (start == end - 1) — a fallback edge spanning MORE
        // than one raw codepoint would let the search "invent" an
        // unknown multi-character piece, which real sentencepiece never
        // does (unknown runs are merged in a POST-processing step below,
        // not by widening the lattice edge itself).
        final score =
            knownScore ?? (end - start == 1 ? _unkFallbackScore : null);
        if (score == null) continue;
        final total = dp[start] + score;
        if (total > dp[end]) {
          dp[end] = total;
          back[end] = start;
        }
      }
    }

    // Backtrace, then merge consecutive unknown-fallback spans into one.
    final spans = <(int start, int end, bool known)>[];
    var pos = n;
    while (pos > 0) {
      final start = back[pos];
      final candidate = String.fromCharCodes(cps, start, pos);
      spans.add((start, pos, _scoreByPiece.containsKey(candidate)));
      pos = start;
    }
    spans.length; // (spans built end-to-start; reverse below)
    final ordered = spans.reversed.toList();

    final result = <String>[];
    var i = 0;
    while (i < ordered.length) {
      final (start, end, known) = ordered[i];
      if (known) {
        result.add(String.fromCharCodes(cps, start, end));
        i++;
        continue;
      }
      var runEnd = end;
      var j = i + 1;
      while (j < ordered.length && !ordered[j].$3) {
        runEnd = ordered[j].$2;
        j++;
      }
      result.add(String.fromCharCodes(cps, start, runEnd));
      i = j;
    }
    return result;
  }
}

// ---------------------------------------------------------------------
// The joint Marian vocabulary (piece <-> id) and the trivial decoder.
// ---------------------------------------------------------------------

class MarianVocabulary {
  final Map<String, int> _idByPiece;
  final Map<int, String> _pieceById;
  final int unkId;
  final int eosId;
  final int padId;

  MarianVocabulary(Map<String, int> idByPiece)
      : _idByPiece = Map.unmodifiable(idByPiece),
        _pieceById = Map.unmodifiable({
          for (final e in idByPiece.entries) e.value: e.key,
        }),
        unkId = idByPiece['<unk>'] ?? 1,
        eosId = idByPiece['</s>'] ?? 0,
        padId = idByPiece['<pad>'] ??
            (idByPiece.values.isEmpty
                ? 0
                : idByPiece.values.reduce((a, b) => a > b ? a : b));

  factory MarianVocabulary.fromJsonBytes(Uint8List bytes) {
    final raw = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    return MarianVocabulary({
      for (final e in raw.entries) e.key: (e.value as num).toInt(),
    });
  }

  /// [piece]'s id, or [unkId] when it is not a vocabulary entry.
  int idOf(String piece) => _idByPiece[piece] ?? unkId;

  /// [id]'s piece text, or the literal `<unk>` surface when [id] is not
  /// one this vocabulary names (decoding an id the model should never
  /// actually emit).
  String pieceOf(int id) => _pieceById[id] ?? '<unk>';

  List<int> encodeIds(List<String> pieces) => pieces.map(idOf).toList();

  /// Joins the pieces for [ids], strips the ▁ space-escape back to a
  /// literal space, and trims — dropping EOS/pad ids rather than
  /// rendering them as text.
  String decodeIds(Iterable<int> ids) {
    final buffer = StringBuffer();
    for (final id in ids) {
      if (id == eosId || id == padId) continue;
      buffer.write(pieceOf(id));
    }
    return buffer.toString().replaceAll(_spaceEscape, ' ').trim();
  }
}
