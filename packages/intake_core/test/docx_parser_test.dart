// Word documents (.docx) as reading text (owner, 17 Nov 2026: "Trellis
// opens .docx files directly"). Fixtures are built in memory, as the EPUB
// ones are; the real test book is David Friedman's "Legal Systems Very
// Different from Ours", whose shape these follow: Heading styles, a
// printed table of contents, footnotes numbered afresh in each chapter.
import 'package:intake_core/intake_core.dart';
import 'package:test/test.dart';

import 'fixtures/docx_fixtures.dart' as fx;

List<String> texts(DocxDoc d) => [
      for (final b in d.blocks)
        switch (b) {
          HeadingBlock(:final level, :final text) => 'H$level $text',
          TextBlock(:final text) => text,
          SegmentBlock(:final content) => 'SEG $content',
          FigureBlock(:final alt) => 'FIG $alt',
        }
    ];

void main() {
  test('paragraphs are prose and Heading styles are headings', () {
    final d = parseDocx(fx.docx(body: [
      fx.p('Introduction', style: 'Heading1'),
      fx.p('Almost forty years ago I became interested.'),
      fx.p('The Law Code', style: 'Heading2'),
      fx.p('Laws originated as statutes.'),
    ]));
    expect(texts(d), [
      'H1 Introduction',
      'Almost forty years ago I became interested.',
      'H2 The Law Code',
      'Laws originated as statutes.',
    ]);
  });

  test('a heading is known by its style name, its base style or its '
      'outline level, not only by the id Word uses in English', () {
    final d = parseDocx(fx.docx(styles: [
      fx.style('berschrift1', name: 'heading 1'),
      fx.style('MyChapter', name: 'My Chapter', basedOn: 'berschrift1'),
      fx.style('Part', name: 'Part', outlineLvl: 0),
    ], body: [
      fx.p('Erstes Kapitel', style: 'berschrift1'),
      fx.p('Second', style: 'MyChapter'),
      fx.p('Third', style: 'Part'),
      fx.p('Fourth', outlineLvl: 1),
    ]));
    expect(texts(d), ['H1 Erstes Kapitel', 'H1 Second', 'H1 Third', 'H2 Fourth']);
  });

  test('runs join into one paragraph, and spaces, tabs and breaks fold to '
      'one space', () {
    final d = parseDocx(fx.docx(body: [
      fx.raw('<w:p><w:r><w:t xml:space="preserve">The  Chinese </w:t></w:r>'
          '<w:r><w:rPr><w:i/></w:rPr><w:t>legal</w:t></w:r><w:r><w:tab/>'
          '<w:t>system</w:t><w:br/><w:t>originated.</w:t></w:r></w:p>'),
    ]));
    expect(texts(d), ['The Chinese legal system originated.']);
  });

  test('the printed table of contents, deleted text, hidden text and field '
      'codes are left out', () {
    final d = parseDocx(fx.docx(body: [
      fx.p('Introduction2', style: 'TOC1'),
      fx.p('1.Imperial Chinese Law4', style: 'TOC1'),
      // An entry the field made without a TOC style, as Friedman's last.
      fx.raw('<w:p><w:r><w:fldChar w:fldCharType="begin"/></w:r>'
          '<w:r><w:instrText xml:space="preserve"> TOC \\o "1-3" </w:instrText></w:r>'
          '<w:r><w:fldChar w:fldCharType="separate"/></w:r>'
          '<w:r><w:t>Romani Law21</w:t></w:r></w:p>'),
      fx.p('Bibliography260'),
      fx.raw('<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>'
          '<w:r><w:t>Index270</w:t></w:r>'
          '<w:r><w:fldChar w:fldCharType="end"/></w:r>'
          '<w:r><w:t>Introduction</w:t></w:r></w:p>'),
      fx.raw('<w:p><w:r><w:fldChar w:fldCharType="begin"/></w:r>'
          '<w:r><w:instrText> PAGE </w:instrText></w:r>'
          '<w:r><w:fldChar w:fldCharType="separate"/></w:r>'
          '<w:r><w:t>Kept</w:t></w:r>'
          '<w:r><w:fldChar w:fldCharType="end"/></w:r>'
          '<w:del w:id="1"><w:r><w:delText>gone</w:delText></w:r></w:del>'
          '<w:ins w:id="2"><w:r><w:t xml:space="preserve"> and added</w:t></w:r></w:ins>'
          '<w:r><w:rPr><w:vanish/></w:rPr><w:t>hidden</w:t></w:r></w:p>'),
    ]));
    expect(texts(d), ['H1 Introduction', 'Kept and added']);
  });

  test('footnote marks are raised numbers, and the notes follow their '
      'chapter under Notes', () {
    final d = parseDocx(fx.docx(
      body: [
        fx.p('Imperial Chinese Law', style: 'Heading1'),
        fx.raw('<w:p><w:r><w:t>Legalists and Confucianists.</w:t></w:r>'
            '${fx.noteRef(2)}<w:r><w:t xml:space="preserve"> Then.</w:t></w:r>'
            '${fx.noteRef(3)}</w:p>'),
        fx.p('Romani Law', style: 'Heading1'),
        fx.raw('<w:p><w:r><w:t>Gypsies.</w:t></w:r>${fx.noteRef(4)}</w:p>'),
      ],
      footnotes: {
        2: 'Bodde and Morris, Law in Imperial China.',
        3: 'Id. at 4.',
        4: 'Weyrauch 1997.',
      },
      restartEachSection: true,
    ));
    expect(texts(d), [
      'H1 Imperial Chinese Law',
      'Legalists and Confucianists.¹ Then.²',
      'H2 Notes',
      '¹ Bodde and Morris, Law in Imperial China.',
      '² Id. at 4.',
      'H1 Romani Law',
      'Gypsies.¹',
      'H2 Notes',
      '¹ Weyrauch 1997.',
    ]);
  });

  test('without a restart in each section, notes are numbered straight '
      'through the book', () {
    final d = parseDocx(fx.docx(
      body: [
        fx.p('One', style: 'Heading1'),
        fx.raw('<w:p><w:r><w:t>A.</w:t></w:r>${fx.noteRef(7)}</w:p>'),
        fx.p('Two', style: 'Heading1'),
        fx.raw('<w:p><w:r><w:t>B.</w:t></w:r>${fx.noteRef(8)}</w:p>'),
      ],
      footnotes: {7: 'First.', 8: 'Second.'},
    ));
    expect(texts(d), [
      'H1 One', 'A.¹', 'H2 Notes', '¹ First.',
      'H1 Two', 'B.²', 'H2 Notes', '² Second.',
    ]);
  });

  test('a document with no headings keeps its notes at the end', () {
    final d = parseDocx(fx.docx(
      body: [
        fx.raw('<w:p><w:r><w:t>A.</w:t></w:r>${fx.noteRef(1)}</w:p>'),
        fx.p('More.'),
      ],
      footnotes: {1: 'Note.'},
    ));
    expect(texts(d), ['A.¹', 'More.', 'H1 Notes', '¹ Note.']);
  });

  test('a web link keeps its words and its address', () {
    final d = parseDocx(fx.docx(
      body: [
        fx.raw('<w:p><w:r><w:t xml:space="preserve">See </w:t></w:r>'
            '<w:hyperlink r:id="rIdL1"><w:r><w:t>the site</w:t></w:r>'
            '</w:hyperlink><w:r><w:t>.</w:t></w:r></w:p>'),
      ],
      links: {'rIdL1': 'http://www.daviddfriedman.com/'},
    ));
    final b = d.blocks.single as TextBlock;
    expect(b.text, 'See the site.');
    expect(b.links,
        [const TextLink(start: 4, end: 12, href: 'http://www.daviddfriedman.com/')]);
  });

  test('list items carry their bullet or their number', () {
    final d = parseDocx(fx.docx(
      numbering: fx.numbering(),
      body: [
        fx.p('Apples', num: 1),
        fx.p('Pears', num: 1),
        fx.p('First step', num: 2),
        fx.p('Inner', num: 2, level: 1),
        fx.p('Second step', num: 2),
      ],
    ));
    expect(texts(d), [
      '• Apples',
      '• Pears',
      '1. First step',
      'a) Inner',
      '2. Second step',
    ]);
  });

  test('a table reads a row at a time, each cell under its column', () {
    final d = parseDocx(fx.docx(body: [
      fx.table([
        ['', 'Ounces', 'Ells'],
        ['Male thrall', '12', '72'],
        ['Wergeld for free man', '100', '600'],
      ]),
    ]));
    expect(texts(d), [
      'Male thrall; Ounces: 12; Ells: 72.',
      'Wergeld for free man; Ounces: 100; Ells: 600.',
    ]);
  });

  test('a one-column table is a layout box: its paragraphs are prose', () {
    final d = parseDocx(fx.docx(body: [
      fx.table([
        ['A boxed aside.'],
        ['And its second line.'],
      ]),
    ]));
    expect(texts(d), ['A boxed aside.', 'And its second line.']);
  });

  test('the title comes from the document, else a Title before any text, '
      'else the file name', () {
    expect(
        parseDocx(fx.docx(title: 'Legal Systems', body: [fx.p('x')])).title,
        'Legal Systems');
    expect(
        parseDocx(fx.docx(body: [fx.p('My Essay', style: 'Title'), fx.p('x')]))
            .title,
        'My Essay');
    // A Title-styled heading later on is a chapter, not the book's name.
    final late = parseDocx(
        fx.docx(body: [fx.p('x'), fx.p('Bibliography', style: 'Title')]),
        sourceName: 'Legal Systems Very Different Complete.docx');
    expect(late.title, 'Legal Systems Very Different Complete');
    expect(texts(late), ['x', 'H1 Bibliography']);
    expect(parseDocx(fx.docx(body: [fx.p('x')])).title, 'Untitled');
  });

  test('text boxes are read once, after their paragraph', () {
    final d = parseDocx(fx.docx(body: [
      fx.raw('<w:p><w:r><w:t>Body.</w:t></w:r><w:r><mc:AlternateContent>'
          '<mc:Choice Requires="wps"><w:drawing><wps:txbx><w:txbxContent>'
          '<w:p><w:r><w:t>Boxed.</w:t></w:r></w:p></w:txbxContent></wps:txbx>'
          '</w:drawing></mc:Choice><mc:Fallback><w:pict><v:textbox>'
          '<w:txbxContent><w:p><w:r><w:t>Boxed.</w:t></w:r></w:p>'
          '</w:txbxContent></v:textbox></w:pict></mc:Fallback>'
          '</mc:AlternateContent></w:r></w:p>'),
    ]));
    expect(texts(d), ['Body.', 'Boxed.']);
  });

  test('a file that is not a Word document is refused in words', () {
    expect(
        () => parseDocx([1, 2, 3]),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('Word document'))));
    expect(
        () => parseDocx(fx.zip({'hello.txt': 'hi'})),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('Word document'))));
  });

  test('a declared size over the cap is refused before anything inflates',
      () {
    expect(
        () => parseDocx(fx.docx(body: [fx.p('x')]), maxUncompressedBytes: 100),
        throwsA(isA<DocxTooLargeException>()));
  });
}
