import 'dart:typed_data';

import 'package:intake_core/intake_core.dart';
import 'package:test/test.dart';

/// PDF pages to reading blocks (1.6.0, owner: "also read other formats
/// like PDF please"). The pages here are laid out by hand the way PDFium
/// reports them: characters in content order, each with its box and font
/// size, origin at the bottom left.

/// One line of text set at ([x], [y]) where y is the baseline.
typedef _Line = ({String text, double x, double y, double size});

_Line at(double x, double y, String text, {double size = 10}) =>
    (text: text, x: x, y: y, size: size);

/// Lays [lines] out with a fixed advance of half the font size, and a
/// line end between them as PDFium gives one.
PdfPageChars page(List<_Line> lines,
    {double width = 600, double height = 800, bool rtl = false}) {
  final text = StringBuffer();
  final boxes = <double>[];
  final sizes = <double>[];
  void put(String ch, double l, double b, double r, double t, double s) {
    text.write(ch);
    boxes.addAll([l, b, r, t]);
    sizes.add(s);
  }

  for (final line in lines) {
    final adv = line.size / 2;
    for (var i = 0; i < line.text.length; i++) {
      final ch = line.text[i];
      final x = rtl ? line.x - (i + 1) * adv : line.x + i * adv;
      if (ch == ' ') {
        put(ch, x, line.y, x + adv, line.y, line.size);
      } else {
        put(ch, x, line.y, x + adv * 0.9, line.y + line.size * 0.7,
            line.size);
      }
    }
    put('\r', 0, 0, 0, 0, line.size);
    put('\n', 0, 0, 0, 0, line.size);
  }
  return PdfPageChars(
      width: width,
      height: height,
      text: text.toString(),
      boxes: Float32List.fromList(boxes),
      sizes: Float32List.fromList(sizes));
}

/// Body lines down a column from [top], 12 apart.
List<_Line> column(double x, double top, List<String> lines,
        {double size = 10, double pitch = 12}) =>
    [
      for (var i = 0; i < lines.length; i++)
        at(x, top - i * pitch, lines[i], size: size),
    ];

List<String> texts(PdfDoc doc) => [for (final b in doc.blocks) b.text];

void main() {
  group('lines into paragraphs', () {
    test('the lines of one paragraph join with spaces, in order', () {
      final doc = pdfToBlocks([
        page(column(50, 700, [
          'The harbour was quiet that',
          'morning, and the boats lay',
          'still on the water.',
        ])),
      ]);

      expect(texts(doc), [
        'The harbour was quiet that morning, and the boats lay still on '
            'the water.'
      ]);
      expect(doc.blocks.single.heading, isFalse);
    });

    test('a wider gap between lines starts a new paragraph', () {
      final doc = pdfToBlocks([
        page([
          ...column(50, 700, ['First paragraph runs on', 'for two lines.']),
          ...column(50, 652, ['Second paragraph is', 'here below it.']),
        ]),
      ]);

      expect(texts(doc), [
        'First paragraph runs on for two lines.',
        'Second paragraph is here below it.',
      ]);
    });

    test('an indented line starts a new paragraph', () {
      final doc = pdfToBlocks([
        page([
          at(50, 700, 'The first paragraph ends'),
          at(50, 688, 'on this line here.'),
          at(65, 676, 'The second one begins'),
          at(50, 664, 'with an indent.'),
        ]),
      ]);

      expect(texts(doc), [
        'The first paragraph ends on this line here.',
        'The second one begins with an indent.',
      ]);
    });

    test('a word broken at the line end with a hyphen is made whole', () {
      final doc = pdfToBlocks([
        page(column(50, 700, ['It was an extra-', 'ordinary morning.'])),
      ]);

      expect(texts(doc), ['It was an extraordinary morning.']);
    });

    test('a gap between two words on a line with no space character is '
        'still a space', () {
      final doc = pdfToBlocks([
        page([at(50, 700, 'Hello'), at(80, 700, 'there.')]),
      ]);

      expect(texts(doc), ['Hello there.']);
    });
  });

  test('right-to-left paragraphs are told apart by their indent, which '
      'is on the right', () {
    final doc = pdfToBlocks([
      page([
        at(500, 700, 'שלום עולם טוב מאוד'),
        at(500, 688, 'בוקר טוב לכם.'),
        at(485, 676, 'פסקה שנייה מתחילה'),
        at(500, 664, 'כאן ונגמרת.'),
      ], rtl: true),
    ]);

    expect(texts(doc), [
      'שלום עולם טוב מאוד בוקר טוב לכם.',
      'פסקה שנייה מתחילה כאן ונגמרת.',
    ]);
  });

  group('headings', () {
    test('a short line set larger than the body is a heading', () {
      final doc = pdfToBlocks([
        page([
          at(50, 740, 'The Harbour', size: 18),
          ...column(50, 700, [
            'The harbour was quiet that',
            'morning, and the boats lay',
            'still on the water.',
          ]),
        ]),
      ]);

      expect(doc.blocks.map((b) => (b.heading, b.text)), [
        (true, 'The Harbour'),
        (
          false,
          'The harbour was quiet that morning, and the boats lay still on '
              'the water.'
        ),
      ]);
    });
  });

  group('reading order', () {
    test('two columns: the left one is read to its foot before the right '
        'one, and a title across both comes first', () {
      final doc = pdfToBlocks([
        page([
          at(50, 760, 'A Title Across Both Columns Here', size: 18),
          // As a typesetter may write them: line by line across the page.
          at(50, 700, 'Left column first'),
          at(320, 700, 'Right column first'),
          at(50, 688, 'line and second.'),
          at(320, 688, 'line and second.'),
          at(50, 652, 'Left again, below.'),
          at(320, 652, 'Right again, below.'),
        ]),
      ]);

      expect(texts(doc), [
        'A Title Across Both Columns Here',
        'Left column first line and second.',
        'Left again, below.',
        'Right column first line and second.',
        'Right again, below.',
      ]);
      expect(doc.untrustedPages, isEmpty);
    });

    test('a page set in more columns than two keeps the order the file '
        'gives, and is named as one whose order can’t be trusted', () {
      final doc = pdfToBlocks([
        page([
          at(40, 700, 'One one one.'),
          at(230, 700, 'Two two two.'),
          at(420, 700, 'Three three.'),
          at(40, 660, 'Four four.'),
          at(230, 660, 'Five five.'),
          at(420, 660, 'Six six six.'),
        ]),
      ]);

      expect(doc.untrustedPages, [1]);
      expect(texts(doc).join(' '),
          'One one one. Two two two. Three three. Four four. Five five. '
          'Six six six.');
    });

    test('right-to-left lines are kept whole, in the order given', () {
      final doc = pdfToBlocks([
        page([
          at(500, 700, 'שלום עולם טוב'),
          at(500, 688, 'בוקר טוב לכם.'),
        ], rtl: true),
      ]);

      expect(texts(doc), ['שלום עולם טוב בוקר טוב לכם.']);
    });
  });

  group('what repeats on every page', () {
    List<PdfPageChars> book(int pages) => [
          for (var p = 1; p <= pages; p++)
            page([
              at(50, 780, 'The Harbour Book'),
              ...column(50, 700, [
                'Page $p begins with its own',
                'words and ends them here.',
              ]),
              at(290, 20, '$p'),
            ]),
        ];

    test('a running head and the page numbers are left out', () {
      final doc = pdfToBlocks(book(4));

      expect(texts(doc), [
        for (var p = 1; p <= 4; p++)
          'Page $p begins with its own words and ends them here.',
      ]);
    });

    test('each block knows the page it starts on', () {
      final doc = pdfToBlocks(book(4));

      expect([for (final b in doc.blocks) b.page], [1, 2, 3, 4]);
      expect(doc.pageCount, 4);
    });

    test('in a file of two pages, what heads both of them is a running '
        'head too', () {
      final doc = pdfToBlocks(book(2));

      expect(texts(doc), [
        for (var p = 1; p <= 2; p++)
          'Page $p begins with its own words and ends them here.',
      ]);
    });

    test('a title set large is kept, though a small running head says '
        'the same words', () {
      final doc = pdfToBlocks([
        for (var p = 1; p <= 3; p++)
          page([
            at(400, 785, 'Harbour Days', size: 8),
            if (p == 1) at(50, 745, 'Harbour Days', size: 20),
            ...column(50, 700, ['Page $p has words of its own.']),
          ]),
      ]);

      expect(texts(doc), [
        'Harbour Days',
        for (var p = 1; p <= 3; p++) 'Page $p has words of its own.',
      ]);
      expect(doc.blocks.first.heading, isTrue);
    });

    test('only the outermost lines of a page can be running heads: body '
        'lines near the edge that happen to repeat are kept', () {
      // Small margins: the body reaches into the top and bottom tenth.
      List<_Line> body(int p) => column(50, 770, [
            'The same line opens each page.',
            'And the same second line too.',
            'Then page $p says its own thing',
            'and ends it here.',
          ]);
      final doc = pdfToBlocks([
        for (var p = 1; p <= 3; p++)
          page([at(50, 790, 'A Running Head', size: 8), ...body(p)]),
      ]);

      expect(texts(doc), [
        for (var p = 1; p <= 3; p++)
          'The same line opens each page. And the same second line too. '
              'Then page $p says its own thing and ends it here.',
      ]);
    });

    test('a lone page number is left out even in a short file', () {
      final doc = pdfToBlocks([
        page([
          ...column(50, 700, ['Only one page of words.']),
          at(290, 20, '1'),
        ]),
      ]);

      expect(texts(doc), ['Only one page of words.']);
    });
  });

  test('a paragraph that runs over the page break is one paragraph, '
      'anchored where it starts', () {
    final doc = pdfToBlocks([
      page(column(50, 700, ['The sentence starts on one', 'page and then'])),
      page(column(50, 700, ['carries on over the break.', 'It ends here.'])),
    ]);

    expect(texts(doc), [
      'The sentence starts on one page and then carries on over the '
          'break. It ends here.'
    ]);
    expect(doc.blocks.single.page, 1);
  });

  group('the title', () {
    final pages = [
      page([
        at(50, 740, 'The Harbour', size: 18),
        ...column(50, 700, ['Words of the body here.', 'And more of them.']),
      ]),
    ];

    test('is the file’s own title when it has a real one', () {
      expect(
          pdfToBlocks(pages, metaTitle: ' Harbour Days ', sourceName: 'x.pdf')
              .title,
          'Harbour Days');
    });

    test('else the first heading on the first page', () {
      expect(pdfToBlocks(pages, sourceName: 'scan0001.pdf').title,
          'The Harbour');
      expect(
          pdfToBlocks(pages,
                  metaTitle: 'Microsoft Word - draft3.docx',
                  sourceName: 'x.pdf')
              .title,
          'The Harbour');
    });

    test('else the file’s name without its ending', () {
      final plain = [
        page(column(50, 700, ['Words of the body here.', 'And more.'])),
      ];
      expect(pdfToBlocks(plain, sourceName: 'Tide tables.PDF').title,
          'Tide tables');
      expect(pdfToBlocks(plain).title, 'Untitled PDF');
    });
  });

  group('pages with no text', () {
    test('a file of pictures of pages has no words, and says which pages',
        () {
      final doc = pdfToBlocks([page([]), page([])], sourceName: 'scan.pdf');

      expect(doc.blocks, isEmpty);
      expect(doc.hasText, isFalse);
      expect(doc.textlessPages, [1, 2]);
    });

    test('one picture page among pages of text is only noted', () {
      final doc = pdfToBlocks([
        page(column(50, 700, ['Words of the body here.'])),
        page([]),
      ]);

      expect(doc.hasText, isTrue);
      expect(doc.textlessPages, [2]);
    });
  });

  test('control characters and stray whitespace never reach the text', () {
    final doc = pdfToBlocks([
      page([at(50, 700, '  Spaced   out\u0000 words.  ')]),
    ]);

    expect(texts(doc), ['Spaced out words.']);
  });
}
