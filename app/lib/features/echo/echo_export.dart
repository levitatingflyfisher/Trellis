/// Campaign 4 Phase 5's export: named for what actually exists in this
/// schema, not for what an earlier spec draft imagined. There is no
/// highlight/passage/marginalia table here — [WordLedger] holds individual
/// words the reader's hand collected (ADR-0003 law 2), and [Captures] holds
/// audio bookmarks (sentence-snapped once a transcript exists, honestly
/// unbound otherwise). "Export highlights" would have overclaimed; this
/// exports the word ledger and captures, and says so.
library;

import 'dart:convert';

typedef LedgerExportWord = ({
  String word,
  String? lang,
  String? workTitle,
  int addedAtMs,
});

typedef LedgerExportCapture = ({
  String workTitle,
  int positionMs,
  int? segmentIdx,
  int createdAtMs,
});

String _mmss(int ms) {
  final totalSeconds = ms ~/ 1000;
  final m = totalSeconds ~/ 60;
  final s = totalSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// Front-matter-free, plain Markdown — the KOReader-loved shape the spec
/// asked for, applied honestly to what this schema actually records.
/// Newest first in both sections, matching [LedgerDao.wordsOf]'s own
/// ordering.
String buildLedgerMarkdown({
  required String profileName,
  required List<LedgerExportWord> words,
  required List<LedgerExportCapture> captures,
}) {
  final sortedWords = [...words]
    ..sort((a, b) => b.addedAtMs.compareTo(a.addedAtMs));
  final sortedCaptures = [...captures]
    ..sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));

  final buf = StringBuffer('# Word ledger — $profileName\n\n');
  if (sortedWords.isEmpty && sortedCaptures.isEmpty) {
    buf.writeln('Nothing collected yet.');
    return buf.toString();
  }

  if (sortedWords.isEmpty) {
    buf.writeln('Nothing collected yet.');
  } else {
    for (final w in sortedWords) {
      final bits = [
        if (w.workTitle != null) w.workTitle!,
        if (w.lang != null) w.lang!,
      ];
      buf.writeln(
          bits.isEmpty ? '- ${w.word}' : '- ${w.word} (${bits.join(', ')})');
    }
  }

  buf.writeln('\n# Captures\n');
  if (sortedCaptures.isEmpty) {
    buf.writeln('None yet.');
  } else {
    for (final c in sortedCaptures) {
      final where = c.segmentIdx != null
          ? 'sentence ${c.segmentIdx}'
          : '${_mmss(c.positionMs)} (unbound — no transcript yet at capture time)';
      buf.writeln('- ${c.workTitle} — $where');
    }
  }
  return buf.toString();
}

/// The same data, structured, for anything that wants to parse it rather
/// than read it.
String buildLedgerJson({
  required String profileName,
  required List<LedgerExportWord> words,
  required List<LedgerExportCapture> captures,
}) {
  return const JsonEncoder.withIndent('  ').convert({
    'profileName': profileName,
    'words': [
      for (final w in words)
        {
          'word': w.word,
          'lang': w.lang,
          'workTitle': w.workTitle,
          'addedAtMs': w.addedAtMs,
        },
    ],
    'captures': [
      for (final c in captures)
        {
          'workTitle': c.workTitle,
          'positionMs': c.positionMs,
          'segmentIdx': c.segmentIdx,
          'createdAtMs': c.createdAtMs,
        },
    ],
  });
}
