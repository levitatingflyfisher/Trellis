// Port tests for donor `parseEpubFile` and its helpers (ohPrimer index.html
// ~1701-1833, 2175-2395): spine walk, nav/NCX TOC, front-matter skips,
// figure/image collection, content stripping. The donor JS is the spec.
import 'package:intake_core/intake_core.dart';
import 'package:test/test.dart';

import 'fixtures/epub_fixtures.dart' as fx;

void main() {
  group('invalid EPUBs (donor error messages)', () {
    test('no container.xml', () {
      expect(
          () => parseEpub(fx.zipWithoutContainer()),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              'Invalid EPUB: no container.xml')));
    });

    test('no rootfile', () {
      expect(
          () => parseEpub(fx.zipWithoutRootfile()),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', 'Invalid EPUB: no rootfile')));
    });

    test('missing OPF', () {
      expect(
          () => parseEpub(fx.zipWithMissingOpf()),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', 'Invalid EPUB: cannot read OPF')));
    });
  });

  group('EPUB3 fixture', () {
    late EpubDoc doc;
    setUpAll(() => doc = parseEpub(fx.epub3()));

    test('dc:title wins', () {
      expect(doc.title, 'The Test Book');
    });

    test('semantic copyright page is skipped with its epub:type label', () {
      expect(doc.skipped, contains('copyright-page'));
    });

    test('spine order yields three chapters, fallback marker deduped', () {
      expect(doc.chapters.map((c) => c.title),
          ['Chapter One', 'Section Two', 'Chapter Three']);
    });

    test('spine item text is decoded as UTF-8 (JSZip async("text"))', () {
      final texts = doc.chapters[0].blocks.whereType<TextBlock>().toList();
      expect(texts.first.text, startsWith('The naïve opening paragraph.'));
    });

    test('each <p> becomes its own text block (block-boundary flush)', () {
      final texts = doc.chapters[0].blocks.whereType<TextBlock>().toList();
      expect(texts, hasLength(2));
      expect(texts[1].text, startsWith('A second paragraph.'));
    });

    test('h3-only item: chapter titled by extractChapterTitle, h3 stays as '
        'a text block (donor quirk)', () {
      final c2 = doc.chapters[1];
      expect(c2.title, 'Section Two');
      expect(c2.blocks.whereType<TextBlock>().map((b) => b.text),
          contains('Section Two'));
    });

    test('img src resolves against the spine item directory', () {
      final figs = doc.chapters[2].blocks.whereType<FigureBlock>().toList();
      expect(figs, hasLength(1));
      expect(figs.single.src, 'images/pic.png');
      expect(figs.single.alt, 'A pic');
    });

    test('image bytes found via findZipImage basename fallback (OPF-root vs '
        'zip-root mismatch, donor H6) with manifest mime', () {
      expect(doc.images, hasLength(1));
      final img = doc.images.single;
      expect(img.id, 'images/pic.png');
      expect(img.mime, 'image/png');
      expect(img.bytes, fx.picBytes);
    });

    test('pre and table become segments', () {
      final segs = doc.chapters[2].blocks.whereType<SegmentBlock>().toList();
      expect(
          segs.map((s) => s.kind),
          containsAll([
            IntakeSegmentKind.code,
            IntakeSegmentKind.table,
          ]));
      expect(
          segs.firstWhere((s) => s.kind == IntakeSegmentKind.table).content,
          contains('cellA'));
      expect(segs.map((s) => s.content), contains('let x = 1;\nlet z = 3;'));
    });

    test('class-based div heuristic: code and equation divs become segments',
        () {
      final segs = doc.chapters[2].blocks.whereType<SegmentBlock>().toList();
      expect(segs.map((s) => s.content), contains('let y = 2;'));
      final math =
          segs.where((s) => s.kind == IntakeSegmentKind.math).toList();
      expect(math.map((s) => s.content), contains('E = mc^2'));
    });

    test('epub:type footnote content is stripped', () {
      final all = doc.chapters
          .expand((c) => c.blocks)
          .whereType<TextBlock>()
          .map((b) => b.text)
          .join(' ');
      expect(all, isNot(contains('FOOTNOTE')));
    });

    test('nav TOC parsed with depths, hrefs resolved to the OPF root', () {
      expect(
          doc.toc.map((e) => (e.title, e.depth, e.href)),
          [
            ('One', 0, 'c1.xhtml'),
            ('Three', 0, 'text/c3.xhtml#sec'),
            ('Three-One', 1, 'text/c3.xhtml#sub'),
          ]);
    });

    test('spine anchors point at each item\'s first chapter position', () {
      expect(doc.spineAnchors['c1.xhtml'], (chapter: 0, block: 0));
      expect(doc.spineAnchors['c2.xhtml'], (chapter: 1, block: 0));
      expect(doc.spineAnchors['text/c3.xhtml'], (chapter: 2, block: 0));
      // The skipped front-matter item anchors where the next content begins.
      expect(doc.spineAnchors['front.xhtml'], (chapter: 0, block: 0));
    });
  });

  group('EPUB2 fixture (NCX fallback)', () {
    late EpubDoc doc;
    setUpAll(() => doc = parseEpub(fx.epub2()));

    test('NCX navMap parsed when no nav doc exists, nested depth 1', () {
      expect(
          doc.toc.map((e) => (e.title, e.depth, e.href)),
          [
            ('Start', 0, 'c1.xhtml'),
            ('Deep', 1, 'c1.xhtml#d'),
          ]);
    });

    test('single chapter parsed', () {
      expect(doc.chapters.map((c) => c.title), ['Only Chapter']);
    });
  });

  group('root-OPF fixture (image path quirks, title fallback)', () {
    late EpubDoc doc;
    setUpAll(
        () => doc = parseEpub(fx.epubRootOpf(), sourceName: 'My Book.epub'));

    test('no dc:title: falls back to sourceName minus .epub', () {
      expect(doc.title, 'My Book');
    });

    test('no sourceName either: Untitled', () {
      expect(parseEpub(fx.epubRootOpf()).title, 'Untitled');
    });

    test('percent-encoded img src resolves via decodeURIComponent variant',
        () {
      final img = doc.images.singleWhere((i) => i.id == 'my%20pic.png');
      expect(img.bytes, fx.picBytes);
      // No manifest entry — mime derived from the extension.
      expect(img.mime, 'image/png');
    });

    test('missing image: figure block kept, no image entry', () {
      final figs =
          doc.chapters.single.blocks.whereType<FigureBlock>().toList();
      expect(figs.map((f) => f.src), contains('ghost.png'));
      expect(doc.images.where((i) => i.id == 'ghost.png'), isEmpty);
    });
  });

  group('front-matter heuristics fixture', () {
    late EpubDoc doc;
    setUpAll(() => doc = parseEpub(fx.epubFrontMatterHeuristics()));

    test('"Table of Contents" heading page skipped with the heading label',
        () {
      expect(doc.skipped, contains('Table of Contents'));
    });

    test('items under 80 words skipped as "short section" (donor quirk: '
        'catches legit short chapters too)', () {
      expect(doc.skipped, contains('short section'));
    });

    test('only the real chapter survives', () {
      expect(doc.chapters.map((c) => c.title), ['The Real Chapter']);
    });
  });
}
