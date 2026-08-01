/// StarDict's `.ifo` metadata file: a fixed signature line, then
/// `key=value` lines. This parser reads only the keys this door uses;
/// unrecognized keys are ignored rather than rejected — a dictionary
/// built by a newer/other StarDict tool with extra keys still opens.
library;

const _signature = "StarDict's dict ifo file";

class StarDictIfo {
  const StarDictIfo({
    required this.version,
    required this.bookname,
    required this.wordCount,
    required this.idxFileSize,
    required this.idxOffsetBits,
    this.sameTypeSequence,
    this.synWordCount,
  });

  final String version;
  final String bookname;
  final int wordCount;
  final int idxFileSize;

  /// 32 (the StarDict default) or 64, for dictionaries too large for a
  /// 32-bit .idx offset.
  final int idxOffsetBits;

  /// When set, every entry's .dict body has the same type marker (`h` =
  /// HTML, `m` = plain text, …) and the .dict body omits the per-entry
  /// type byte the format otherwise requires.
  final String? sameTypeSequence;

  final int? synWordCount;

  /// Throws [FormatException] when the signature line is missing or a
  /// required key ([wordCount]/[idxFileSize]/[bookname]/[version]) is
  /// absent — a genuinely malformed/foreign file, not a StarDict variant
  /// this door should silently misread.
  factory StarDictIfo.parse(String content) {
    final lines = content.split('\n');
    if (lines.isEmpty || lines.first.trim() != _signature) {
      throw const FormatException(
          'not a StarDict .ifo file (missing signature line)');
    }
    final kv = <String, String>{};
    for (final line in lines.skip(1)) {
      final eq = line.indexOf('=');
      if (eq < 0) continue;
      kv[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
    }
    String require(String key) {
      final v = kv[key];
      if (v == null) {
        throw FormatException('StarDict .ifo missing required key "$key"');
      }
      return v;
    }

    return StarDictIfo(
      version: require('version'),
      bookname: require('bookname'),
      wordCount: int.parse(require('wordcount')),
      idxFileSize: int.parse(require('idxfilesize')),
      idxOffsetBits:
          kv.containsKey('idxoffsetbits') ? int.parse(kv['idxoffsetbits']!) : 32,
      sameTypeSequence: kv['sametypesequence'],
      synWordCount:
          kv.containsKey('synwordcount') ? int.parse(kv['synwordcount']!) : null,
    );
  }
}
