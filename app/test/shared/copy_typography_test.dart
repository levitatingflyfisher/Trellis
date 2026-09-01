import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// House style for words on screen: no spaced em dashes, and typographic
/// apostrophes and quotes (’ “ ”) rather than typewriter ones (' ").
/// A source scan over string literals in lib/ (the Sundial / Furrow /
/// Peckish / Reckon scan; the fleet has no shared home for it yet).
/// Comments, imports and log lines are ignored.
///
/// Exempt, because their text is not on-screen copy: export file formats
/// (Anki, the What you've built export) and the model registry's ids.
const _exempt = [
  'anki_export_io.dart',
  'echo_export.dart',
  'database.g.dart',
  // Shell arguments for ffmpeg: the quotes are syntax, not prose.
  'ffmpeg_decoder.dart',
  'dsp_ffmpeg_encoder.dart',
];

void main() {
  final literal = RegExp(r'"([^"\\]|\\.)*"' "|" r"'([^'\\]|\\.)*'");

  Iterable<(String, int, String)> literals() sync* {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart'))
        .where((f) => !_exempt.any(f.path.endsWith));
    for (final f in files) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final t = line.trimLeft();
        if (t.startsWith('//') || line.contains('debugPrint(')) continue;
        // A literal marked as code (e.g. a JSON example) keeps its quotes.
        if (line.contains('// copy-typography: code')) continue;
        if (t.startsWith('import ') || t.startsWith('export ')) continue;
        if (t.startsWith('part ')) continue;
        for (final m in literal.allMatches(line)) {
          final lit = m.group(0)!;
          // A literal that is only quote marks is text processing (the
          // voice's symbol table, HTML entity decoding), not copy.
          if (RegExp(r'''^['"][\'"]*['"]$''').hasMatch(lit)) continue;
          yield (f.path, i + 1, lit);
        }
      }
    }
  }

  test('no spaced em dash in on-screen copy', () {
    final hits = [
      for (final (path, line, lit) in literals())
        if (lit.contains(' — ') || lit.endsWith(" —'") || lit.endsWith(' —"'))
          '$path:$line $lit',
    ];
    expect(hits, isEmpty);
  });

  test('no typewriter apostrophe or quote inside on-screen copy', () {
    final apostrophe = RegExp(r"[A-Za-z]'[A-Za-z]");
    final escaped = RegExp(r"[A-Za-z}]\\'[A-Za-z]");
    final hits = [
      for (final (path, line, lit) in literals())
        if ((lit.startsWith('"') &&
                apostrophe.hasMatch(lit.substring(1, lit.length - 1))) ||
            (lit.startsWith("'") &&
                (lit.substring(1, lit.length - 1).contains('"') ||
                    escaped.hasMatch(lit))))
          '$path:$line $lit',
    ];
    expect(hits, isEmpty);
  });
}
