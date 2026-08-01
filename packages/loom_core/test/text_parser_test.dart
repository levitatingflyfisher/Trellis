/// Port of ohPrimer rebuild/test/parsers.test.mjs (12 donor asserts).
///
/// The donor JS (rebuild/src/scripts/20-parsers.js) is the spec; every donor
/// `ok`/`eq` maps to exactly one expect below, in donor order. Donor block
/// types map onto SegmentKind: text→prose, chapter→heading,
/// segment(code)→code, segment(table)→table. Also runs parser output through
/// the tokenizer to confirm the ingestion pipeline, as the donor test does.
import 'package:loom_core/loom_core.dart';
import 'package:test/test.dart';

List<SegmentKind> _kinds(ParsedText d) =>
    d.segments.map((s) => s.kind).toList();

void main() {
  group('parsers: paragraphs', () {
    final d = parseTextFile('Para one line A\nPara one line B\n\nPara two.', 'T');

    test('blank line splits paragraphs', () {
      expect(_kinds(d), [SegmentKind.prose, SegmentKind.prose]);
    });
    test('consecutive lines joined', () {
      expect(d.segments[0].text, 'Para one line A Para one line B');
    });
    test('title carried', () {
      expect(d.title, 'T');
    });
  });

  group('parsers: chapter heading', () {
    final d = parseTextFile('Chapter 1\n\nIt begins.', 'T');

    test('chapter heading detected', () {
      expect(_kinds(d), [SegmentKind.heading, SegmentKind.prose]);
    });
    test('chapter title', () {
      expect(d.segments[0].text, 'Chapter 1');
    });
  });

  group('parsers: divider does not glue paragraphs (M9)', () {
    final d = parseTextFile('First para.\n----------\nSecond para.', 'T');

    test('divider yields two separate text blocks', () {
      expect(_kinds(d), [SegmentKind.prose, SegmentKind.prose]);
    });
    test('first stays intact', () {
      expect(d.segments[0].text, 'First para.');
    });
    test('second not glued onto first', () {
      expect(d.segments[1].text, 'Second para.');
    });
  });

  group('parsers: indented code block', () {
    test('code segment detected', () {
      final d = parseTextFile('Intro\n\n    line1()\n    line2()\n    line3()\n', 'T');
      expect(d.segments.any((s) => s.kind == SegmentKind.code), isTrue);
    });
  });

  group('parsers: table', () {
    test('table segment detected', () {
      final d = parseTextFile('a | b | c\nd | e | f\ng | h | i', 'T');
      expect(d.segments.any((s) => s.kind == SegmentKind.table), isTrue);
    });
  });

  group('parsers: pipeline into tokenizer', () {
    final d = parseTextFile('Chapter 1\n\nThe quick brown fox.', 'T');
    final st = tokenizeDocument(d.segments);

    test('chapter survives into token stream', () {
      expect(st.chapters, hasLength(1));
      expect(st.chapters.single.idx, 0);
      expect(st.chapters.single.title, 'Chapter 1');
    });
    test('prose tokenized', () {
      expect(st.words, ['The', 'quick', 'brown', 'fox.']);
    });
  });
}
