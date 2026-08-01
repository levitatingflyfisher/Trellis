import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/echo/echo_export.dart';

/// Campaign 4 Phase 5's export: named for what actually exists in this
/// schema — the word ledger and captures (audio bookmarks). There is no
/// highlight/passage/marginalia table; an earlier spec draft's "Export
/// highlights" would have overclaimed, so the button and this builder are
/// named "Export word ledger + captures" instead.
void main() {
  final words = [
    (word: 'saudade', lang: 'pt', workTitle: 'Braiding Sweetgrass', addedAtMs: 2000),
    (word: 'hygge', lang: null, workTitle: null, addedAtMs: 1000),
  ];
  final captures = [
    (workTitle: 'The Overstory', positionMs: 125000, segmentIdx: 4, createdAtMs: 3000),
    (workTitle: 'The Overstory', positionMs: 60000, segmentIdx: null, createdAtMs: 500),
  ];

  group('buildLedgerMarkdown', () {
    test('front-matter-free, plain — words newest first, with source and lang',
        () {
      final md = buildLedgerMarkdown(
          profileName: 'Ada', words: words, captures: const []);
      expect(md, startsWith('# Word ledger — Ada'));
      expect(md, isNot(contains('---')), reason: 'no YAML front matter');
      final saudadeLine = md.split('\n').firstWhere((l) => l.contains('saudade'));
      expect(saudadeLine, contains('pt'));
      expect(saudadeLine, contains('Braiding Sweetgrass'));
      // Newest (addedAtMs 2000) before oldest (1000).
      expect(md.indexOf('saudade'), lessThan(md.indexOf('hygge')));
    });

    test('a word with no source work or lang still gets a plain line', () {
      final md = buildLedgerMarkdown(
          profileName: 'Ada', words: words, captures: const []);
      final hyggeLine = md.split('\n').firstWhere((l) => l.contains('hygge'));
      expect(hyggeLine, isNot(contains('null')));
    });

    test('captures get their own section: sentence-snapped when a '
        'transcript existed at capture time, an honest mm:ss otherwise',
        () {
      final md = buildLedgerMarkdown(
          profileName: 'Ada', words: const [], captures: captures);
      expect(md, contains('# Captures'));
      expect(md, contains('The Overstory'));
      final lines =
          md.split('\n').where((l) => l.contains('The Overstory')).toList();
      expect(lines, hasLength(2));
      expect(lines, anyElement(contains('sentence 4')),
          reason: 'segmentIdx 4 means a transcript bound this capture');
      expect(lines, anyElement(allOf(contains('1:00'), contains('unbound'))),
          reason: 'segmentIdx null (60000ms, no transcript yet) is honest, '
              'not guessed');
    });

    test('an empty ledger and no captures produces an honest empty '
        'document, not a blank file', () {
      final md =
          buildLedgerMarkdown(profileName: 'Ada', words: const [], captures: const []);
      expect(md, contains('Nothing collected yet'));
    });

    test('the exact document, byte for byte (the export "golden file" the '
        'spec asked for)', () {
      final md = buildLedgerMarkdown(profileName: 'Ada', words: [
        (word: 'saudade', lang: 'pt', workTitle: 'Braiding Sweetgrass', addedAtMs: 2000),
      ], captures: [
        (workTitle: 'The Overstory', positionMs: 60000, segmentIdx: 4, createdAtMs: 500),
      ]);
      expect(
          md,
          '# Word ledger — Ada\n'
          '\n'
          '- saudade (Braiding Sweetgrass, pt)\n'
          '\n'
          '# Captures\n'
          '\n'
          '- The Overstory — sentence 4\n');
    });
  });

  group('buildLedgerJson', () {
    test('round-trips the same data as structured JSON', () {
      final jsonText = buildLedgerJson(
          profileName: 'Ada', words: words, captures: captures);
      expect(jsonText, contains('"word": "saudade"'));
      expect(jsonText, contains('"profileName": "Ada"'));
      expect(jsonText, contains('"positionMs": 125000'));
    });
  });
}
