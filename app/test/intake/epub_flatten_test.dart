import 'package:flutter_test/flutter_test.dart';
import 'package:intake_core/intake_core.dart';
import 'package:trellis/features/intake/epub_flatten.dart';

/// EPUB chapters → spine segment rows: a heading segment opens each chapter,
/// blocks follow in order, and every intake block kind has a typed home.
void main() {
  test('chapters flatten to heading + blocks with contiguous indices', () {
    const doc = EpubDoc(
      title: 'A Book',
      chapters: [
        EpubChapter(title: 'One', blocks: [
          TextBlock('Hello there.'),
          SegmentBlock(kind: IntakeSegmentKind.code, content: 'x = 1'),
          FigureBlock(src: 'img/map.png', alt: 'A map'),
        ]),
        EpubChapter(title: 'Two', blocks: [
          TextBlock('Second chapter.'),
        ]),
      ],
      toc: [],
      images: [],
      skipped: [],
      spineAnchors: {},
    );

    final rows = flattenEpub(doc);
    expect(rows.map((r) => (r.idx, r.kind, r.text)).toList(), [
      (0, 'heading', 'One'),
      (1, 'prose', 'Hello there.'),
      (2, 'code', 'x = 1'),
      (3, 'figure', 'A map'),
      (4, 'heading', 'Two'),
      (5, 'prose', 'Second chapter.'),
    ]);
  });

  test('table keeps its kind, math maps to code, alt-less figures show src',
      () {
    const doc = EpubDoc(
      title: 'T',
      chapters: [
        EpubChapter(title: 'C', blocks: [
          SegmentBlock(kind: IntakeSegmentKind.table, content: 'a|b'),
          SegmentBlock(kind: IntakeSegmentKind.math, content: 'E=mc^2'),
          FigureBlock(src: 'img/x.png', alt: ''),
        ]),
      ],
      toc: [],
      images: [],
      skipped: [],
      spineAnchors: {},
    );

    final rows = flattenEpub(doc);
    expect(rows.map((r) => (r.kind, r.text)).toList(), [
      ('heading', 'C'),
      ('table', 'a|b'),
      ('code', 'E=mc^2'),
      ('figure', 'img/x.png'),
    ]);
  });

  test('an empty-titled chapter emits no heading row', () {
    const doc = EpubDoc(
      title: 'T',
      chapters: [
        EpubChapter(title: '', blocks: [TextBlock('Body.')]),
      ],
      toc: [],
      images: [],
      skipped: [],
      spineAnchors: {},
    );
    final rows = flattenEpub(doc);
    expect(rows.map((r) => (r.idx, r.kind, r.text)).toList(), [
      (0, 'prose', 'Body.'),
    ]);
  });
}
