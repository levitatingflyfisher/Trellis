/// EPUB parsing, ported from ohPrimer `index.html` (`parseEpubFile`,
/// `walkContent`, `stripNonContent`, `detectFrontMatter`,
/// `extractChapterTitle`, `parseNavToc`, `parseNcxToc`, `resolveHref`,
/// `findZipImage`). The donor JS is the spec, quirks included.
///
/// The donor emits one flat block list with `{type:"chapter"}` markers
/// interleaved; here the same flat walk runs and the markers are then grouped
/// into [EpubChapter]s (every spine item opens with a marker, so the grouping
/// is lossless). Content docs are parsed with the HTML parser — the donor's
/// `text/html` fallback path — since a strict-XHTML first pass isn't
/// available in package:html.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

import 'blocks.dart';

/// A parsed EPUB.
class EpubDoc {
  final String title;
  final List<EpubChapter> chapters;
  final List<TocEntry> toc;
  final List<EpubImage> images;

  /// Labels of skipped front-matter spine items (donor `skipped`).
  final List<String> skipped;

  /// Spine href (OPF-root-relative) → where that item's content begins, for
  /// resolving [TocEntry.href]s (donor `spineAnchors`).
  final Map<String, ({int chapter, int block})> spineAnchors;

  const EpubDoc({
    required this.title,
    required this.chapters,
    required this.toc,
    required this.images,
    required this.skipped,
    required this.spineAnchors,
  });
}

/// One chapter: a donor chapter marker plus the blocks that followed it.
class EpubChapter {
  final String title;
  final List<IntakeBlock> blocks;
  const EpubChapter({required this.title, required this.blocks});
}

/// A TOC entry; [href] is resolved relative to the OPF root directory and may
/// carry a `#fragment`.
class TocEntry {
  final String title;
  final int depth;
  final String href;
  const TocEntry({required this.title, required this.depth, required this.href});
}

/// An image pulled from the zip for a [FigureBlock]; [id] equals the figure's
/// resolved `src`. Figures whose bytes could not be located have no entry.
class EpubImage {
  final String id;
  final Uint8List bytes;
  final String mime;
  const EpubImage({required this.id, required this.bytes, required this.mime});
}

// ───── donor constants ─────

const _blockTags = {
  'p', 'div', 'section', 'article', 'blockquote', 'li', 'ul', 'ol', 'dl', //
  'dt', 'dd', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'header', 'footer', //
  'main', 'aside', 'figure', 'figcaption', 'br', 'hr',
};
const _headingTags = {'h1', 'h2', 'h3', 'h4', 'h5', 'h6'};
const _segmentTags = {
  'table': IntakeSegmentKind.table,
  'pre': IntakeSegmentKind.code,
  'math': IntakeSegmentKind.math,
};
const _stripTags = {'head', 'style', 'script', 'link', 'meta', 'svg'};
const _stripRoles = {
  'doc-footnote', 'doc-pagebreak', 'doc-endnote', 'doc-noteref', //
};

final _wsRe = RegExp(r'\s+');
final _spineTypeRe = RegExp('xhtml|html|xml', caseSensitive: false);
final _navPropRe = RegExp(r'\bnav\b');
final _ncxTypeRe = RegExp('ncx', caseSensitive: false);
final _skipTypesRe =
    RegExp(r'\b(footnote|noteref|pagebreak|endnote|toc|landmarks|page-list)\b');
final _tocTypeRe = RegExp(r'\btoc\b');
final _classSegmentRe = RegExp(r'\b(code|codeblock|math|equation|formula)\b');
final _classMathRe = RegExp('math|equation|formula');
final _frontSemanticRe = RegExp(
  r'\b(frontmatter|copyright-page|copyright|titlepage|halftitlepage|halftitle'
  r'|imprint|colophon|dedication|acknowledgments|toc|landmarks|page-list)\b',
  caseSensitive: false,
);
final _frontHeadingRe = RegExp(
  r'^(copyright|title page|contents|table of contents|colophon|front ?matter'
  r'|acknowledg|dedication|imprint|halftitle|about the (author|book)'
  r'|by the same author|also by|praise for|epigraph|cover)\b',
  caseSensitive: false,
);
const _extensionMime = {
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'svg': 'image/svg+xml',
  'webp': 'image/webp',
  'avif': 'image/avif',
  'bmp': 'image/bmp',
};

// A donor `{type:"chapter",title}` marker in the flat walk output.
class _ChapterMarker {
  final String title;
  _ChapterMarker(this.title);
}

class _ManifestItem {
  final String? href;
  final String? type;
  final String properties;
  _ManifestItem({this.href, this.type, required this.properties});
}

/// Parses EPUB [bytes] (donor `parseEpubFile`).
///
/// [sourceName] plays the donor's `file.name` role: when the OPF has no
/// `dc:title`, the title falls back to it (minus any `.epub` suffix), then to
/// `'Untitled'`.
///
/// Throws [FormatException] with the donor's messages on structurally invalid
/// EPUBs. Missing spine items are skipped silently (the donor warned to the
/// console); a malformed OPF yields an empty doc, as the donor's error-doc
/// path did.
EpubDoc parseEpub(List<int> bytes, {String? sourceName}) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } on ArchiveException {
    throw const FormatException('Invalid EPUB: no container.xml');
  }
  final byName = <String, ArchiveFile>{
    for (final f in archive.files)
      if (f.isFile) f.name: f,
  };
  String? readText(String name) {
    final f = byName[name];
    if (f == null) return null;
    // JSZip's async("text") is a non-fatal UTF-8 decode.
    return utf8.decode(f.content, allowMalformed: true);
  }

  final fallbackTitle = sourceName == null
      ? 'Untitled'
      : sourceName.replaceAll(RegExp(r'\.epub$', caseSensitive: false), '');

  final containerXml = readText('META-INF/container.xml');
  if (containerXml == null) {
    throw const FormatException('Invalid EPUB: no container.xml');
  }

  final opfPath = _rootfilePath(containerXml);
  if (opfPath == null) {
    throw const FormatException('Invalid EPUB: no rootfile');
  }
  final opfDir = opfPath.contains('/')
      ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1)
      : '';

  final opfText = readText(opfPath);
  if (opfText == null) {
    throw const FormatException('Invalid EPUB: cannot read OPF');
  }
  final XmlDocument opfDoc;
  try {
    opfDoc = XmlDocument.parse(opfText);
  } on XmlException {
    // Donor: DOMParser yields an error doc and every query comes back empty.
    return EpubDoc(
        title: fallbackTitle,
        chapters: const [],
        toc: const [],
        images: const [],
        skipped: const [],
        spineAnchors: const {});
  }

  // Metadata — prefer dc:title; iterate metadata children by localName.
  var title = fallbackTitle;
  final metadataEl = _firstXml(opfDoc.rootElement, 'metadata');
  if (metadataEl != null) {
    for (final child in metadataEl.childElements) {
      final t = child.innerText.trim();
      if (child.localName == 'title' && t.isNotEmpty) {
        title = t;
        break;
      }
    }
  }

  // Manifest id → item map (document order preserved for the nav/ncx scans).
  final manifest = <String, _ManifestItem>{};
  for (final it in opfDoc.rootElement.descendantElements) {
    if (it.localName != 'item') continue;
    if ((it.parentElement?.localName ?? '') != 'manifest') continue;
    final id = it.getAttribute('id');
    if (id == null) continue;
    manifest[id] = _ManifestItem(
      href: it.getAttribute('href'),
      type: it.getAttribute('media-type'),
      properties: it.getAttribute('properties') ?? '',
    );
  }

  // Spine order.
  final spineEl = _firstXml(opfDoc.rootElement, 'spine');
  final spineRefs = <_ManifestItem>[];
  if (spineEl != null) {
    for (final si in spineEl.childElements) {
      if (si.localName != 'itemref') continue;
      final m = manifest[si.getAttribute('idref')];
      // Donor filter `m&&m.href&&/xhtml|html|xml/i.test(m.type||"")` — an
      // empty href is falsy and drops the item.
      if (m != null &&
          m.href != null &&
          m.href!.isNotEmpty &&
          _spineTypeRe.hasMatch(m.type ?? '')) {
        spineRefs.add(m);
      }
    }
  }

  // Locate the TOC doc (EPUB3 nav preferred, fallback to EPUB2 NCX).
  _ManifestItem? navItem;
  for (final m in manifest.values) {
    if (_navPropRe.hasMatch(m.properties)) {
      navItem = m;
      break;
    }
  }
  final ncxId = spineEl?.getAttribute('toc');
  _ManifestItem? ncxItem = ncxId != null ? manifest[ncxId] : null;
  if (ncxItem == null) {
    for (final m in manifest.values) {
      if (_ncxTypeRe.hasMatch(m.type ?? '')) {
        ncxItem = m;
        break;
      }
    }
  }

  final flat = <Object>[]; // _ChapterMarker | IntakeBlock
  final skipped = <String>[];
  final flatAnchors = <String, int>{}; // href → flat index

  for (final ref in spineRefs) {
    final href = ref.href!;
    flatAnchors[href] = flat.length;
    final xhtml = readText(opfDir + href) ?? readText(href);
    if (xhtml == null) continue;

    // Donor tries strict XHTML first, falling back to text/html; here the
    // fallback parser is the parser.
    final contentDoc = html_parser.parse(xhtml);
    _stripNonContent(contentDoc);
    final body = contentDoc.body ?? contentDoc.documentElement;
    if (body == null) continue;

    // Skip front-matter / boilerplate spine items.
    final fm = _detectFrontMatter(body);
    if (fm != null) {
      skipped.add(fm);
      continue;
    }

    // Spine-level chapter marker as fallback; deduped below if the walk
    // opens with its own H1/H2 chapter.
    final chapterCount = flat.whereType<_ChapterMarker>().length;
    final fallback =
        _extractChapterTitle(body) ?? 'Chapter ${chapterCount + 1}';
    final fallbackIdx = flat.length;
    flat.add(_ChapterMarker(fallback));

    _walkContent(body, flat, spineHref: href);

    if (flat.length > fallbackIdx + 1 &&
        flat[fallbackIdx] is _ChapterMarker &&
        flat[fallbackIdx + 1] is _ChapterMarker) {
      flat.removeAt(fallbackIdx);
    }
  }

  // Extract image bytes for every figure block (donor collected blobs; the
  // donor's null entries for unfound images are simply omitted here).
  final images = <EpubImage>[];
  final seenSrc = <String>{};
  for (final b in flat) {
    if (b is! FigureBlock) continue;
    final src = b.src;
    if (src.isEmpty || !seenSrc.add(src)) continue;
    final imgFile = _findZipImage(byName, archive, src);
    if (imgFile == null) continue;
    images.add(EpubImage(
      id: src,
      bytes: imgFile.content,
      mime: _mimeFor(src, manifest),
    ));
  }

  // Parse the TOC (donor: any failure just leaves it empty).
  var toc = <TocEntry>[];
  try {
    if (navItem != null && navItem.href != null) {
      final navHref = navItem.href!;
      final navText = readText(opfDir + navHref) ?? readText(navHref);
      if (navText != null) {
        toc = _parseNavToc(html_parser.parse(navText), navHref);
      }
    }
    if (toc.isEmpty && ncxItem != null && ncxItem.href != null) {
      final ncxHref = ncxItem.href!;
      final ncxText = readText(opfDir + ncxHref) ?? readText(ncxHref);
      if (ncxText != null) {
        toc = _parseNcxToc(XmlDocument.parse(ncxText), ncxHref);
      }
    }
  } catch (_) {
    // Donor: console.warn("Primer: TOC parse failed") — toc stays as-is.
  }

  // Group the flat donor stream into chapters and convert the anchors.
  final chapters = <EpubChapter>[];
  final flatPos = <({int chapter, int block})>[];
  List<IntakeBlock>? cur;
  for (final entry in flat) {
    if (entry is _ChapterMarker) {
      cur = <IntakeBlock>[];
      chapters.add(EpubChapter(title: entry.title, blocks: cur));
      flatPos.add((chapter: chapters.length - 1, block: 0));
    } else {
      // Defensive: the donor stream can't lead with content (every spine item
      // opens with a marker), but grouping stays total anyway.
      if (cur == null) {
        cur = <IntakeBlock>[];
        chapters.add(EpubChapter(title: '', blocks: cur));
      }
      flatPos.add((chapter: chapters.length - 1, block: cur.length));
      cur.add(entry as IntakeBlock);
    }
  }
  final spineAnchors = <String, ({int chapter, int block})>{};
  flatAnchors.forEach((href, f) {
    if (chapters.isEmpty) {
      spineAnchors[href] = (chapter: 0, block: 0);
    } else if (f >= flatPos.length) {
      spineAnchors[href] =
          (chapter: chapters.length - 1, block: chapters.last.blocks.length);
    } else {
      spineAnchors[href] = flatPos[f];
    }
  });

  return EpubDoc(
    title: title,
    chapters: chapters,
    toc: toc,
    images: images,
    skipped: skipped,
    spineAnchors: spineAnchors,
  );
}

// ───── XML helpers ─────

String? _rootfilePath(String containerXml) {
  try {
    final doc = XmlDocument.parse(containerXml);
    for (final el in doc.rootElement.descendantElements) {
      if (el.localName == 'rootfile') return el.getAttribute('full-path');
    }
  } on XmlException {
    // Donor: DOMParser error doc → querySelector("rootfile") is null.
  }
  return null;
}

XmlElement? _firstXml(XmlElement root, String localName) {
  if (root.localName == localName) return root;
  for (final el in root.descendantElements) {
    if (el.localName == localName) return el;
  }
  return null;
}

// ───── DOM helpers (package:html) ─────

Iterable<dom.Element> _descendants(dom.Node node) sync* {
  for (final child in node.nodes) {
    if (child is dom.Element) {
      yield child;
      yield* _descendants(child);
    } else {
      yield* _descendants(child);
    }
  }
}

String _epubType(dom.Element el) =>
    el.attributes['epub:type']?.toString() ?? '';

/// Donor `stripNonContent`: drop non-content tags, footnote/pagebreak roles,
/// and any element whose `epub:type` (or bare `type` — donor quirk) matches
/// the skip list.
void _stripNonContent(dom.Document doc) {
  final toRemove = <dom.Element>[];
  for (final el in _descendants(doc)) {
    final role = el.attributes['role'];
    final typeAttr = _epubType(el).isNotEmpty
        ? _epubType(el)
        : (el.attributes['type']?.toString() ?? '');
    if (_stripTags.contains(el.localName) ||
        (role != null && _stripRoles.contains(role)) ||
        (typeAttr.isNotEmpty && _skipTypesRe.hasMatch(typeAttr))) {
      toRemove.add(el);
    }
  }
  for (final el in toRemove) {
    if (el.parentNode != null) el.remove();
  }
}

/// Donor `detectFrontMatter`: a label when the spine item looks like
/// boilerplate (semantic epub:type, telltale first heading, or under 80
/// words), else null.
String? _detectFrontMatter(dom.Element body) {
  final semEls = [
    body,
    ..._descendants(body).where((el) =>
        el.localName == 'section' ||
        el.localName == 'article' ||
        el.localName == 'nav'),
  ];
  for (final el in semEls) {
    final t = _epubType(el);
    if (t.isNotEmpty && _frontSemanticRe.hasMatch(t)) {
      return _frontSemanticRe.firstMatch(t)![0]!.toLowerCase();
    }
  }
  final heading = _descendants(body).where((el) =>
      el.localName == 'h1' ||
      el.localName == 'h2' ||
      el.localName == 'h3');
  if (heading.isNotEmpty) {
    final txt = heading.first.text.trim();
    if (_frontHeadingRe.hasMatch(txt)) {
      return txt.length > 40 ? txt.substring(0, 40) : txt;
    }
  }
  final wc =
      body.text.trim().split(_wsRe).where((w) => w.isNotEmpty).length;
  if (wc < 80) return 'short section';
  return null;
}

/// Donor `extractChapterTitle`: first h1/h2/h3's collapsed text when it is
/// non-empty and under 120 chars.
String? _extractChapterTitle(dom.Element root) {
  for (final el in _descendants(root)) {
    if (el.localName != 'h1' && el.localName != 'h2' && el.localName != 'h3') {
      continue;
    }
    final t = el.text.trim().replaceAll(_wsRe, ' ');
    return (t.isNotEmpty && t.length < 120) ? t : null;
  }
  return null;
}

/// Donor `walkContent`: buffer inline text, flush at block boundaries; H1/H2
/// open chapters, H3-H6 stay text; img/pre/table/math (and code/math-classed
/// divs) become segments.
void _walkContent(dom.Element root, List<Object> blocks,
    {required String spineHref}) {
  var buf = <String>[];
  void flush() {
    final s = buf.join('').replaceAll(_wsRe, ' ').trim();
    if (s.isNotEmpty) blocks.add(TextBlock(s));
    buf = <String>[];
  }

  final spineDir = spineHref.contains('/')
      ? spineHref.substring(0, spineHref.lastIndexOf('/') + 1)
      : '';

  void walk(dom.Node node) {
    if (node is dom.Text) {
      buf.add(node.data);
      return;
    }
    if (node is! dom.Element) return;

    final tag = node.localName ?? '';

    // Image → figure segment, src resolved against the spine item's dir.
    if (tag == 'img') {
      final src = node.attributes['src'] ?? '';
      if (src.isNotEmpty) {
        flush();
        blocks.add(FigureBlock(
          src: _resolveHref(src, spineDir),
          alt: node.attributes['alt'] ?? '',
        ));
      }
      return;
    }

    // Segment-producing tags — capture whole, don't recurse.
    final segKind = _segmentTags[tag];
    if (segKind != null) {
      flush();
      blocks.add(SegmentBlock(kind: segKind, content: node.text.trim()));
      return;
    }
    // Class-based segment heuristic (code blocks styled as divs, equations).
    final cls = (node.attributes['class'] ?? '').toLowerCase();
    if (cls.isNotEmpty && tag == 'div' && _classSegmentRe.hasMatch(cls)) {
      flush();
      final kind = _classMathRe.hasMatch(cls)
          ? IntakeSegmentKind.math
          : IntakeSegmentKind.code;
      blocks.add(SegmentBlock(kind: kind, content: node.text.trim()));
      return;
    }

    // Heading → flush; chapter marker if h1/h2, otherwise plain text.
    if (_headingTags.contains(tag)) {
      flush();
      final headingText = node.text.trim().replaceAll(_wsRe, ' ');
      if ((tag == 'h1' || tag == 'h2') && headingText.isNotEmpty) {
        blocks.add(_ChapterMarker(headingText));
        return;
      }
      if (headingText.isNotEmpty) blocks.add(TextBlock(headingText));
      return;
    }

    final isBlock = _blockTags.contains(tag);
    if (isBlock) flush();
    for (final child in node.nodes.toList()) {
      walk(child);
    }
    if (isBlock) flush();
  }

  walk(root);
  flush();
}

/// Donor `resolveHref`: resolve [href] against directory [dir] (which is
/// itself relative to the OPF root), normalizing `.` and `..`; a `#fragment`
/// survives.
String _resolveHref(String href, String dir) {
  if (href.isEmpty) return '';
  final hash = href.indexOf('#');
  final path = hash >= 0 ? href.substring(0, hash) : href;
  final frag = hash >= 0 ? href.substring(hash + 1) : null;
  if (path.isEmpty) return href;
  final resolved = <String>[];
  for (final seg in (dir + path).split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (resolved.isNotEmpty) resolved.removeLast();
      continue;
    }
    resolved.add(seg);
  }
  return resolved.join('/') + (frag != null ? '#$frag' : '');
}

/// Donor `parseNavToc`: entries from `<nav epub:type="toc">` (else the first
/// nav), depth-first over nested `<ol>`.
List<TocEntry> _parseNavToc(dom.Document navDoc, String navHref) {
  dom.Element? nav;
  for (final n in _descendants(navDoc)) {
    if (n.localName != 'nav') continue;
    if (_tocTypeRe.hasMatch(_epubType(n))) {
      nav = n;
      break;
    }
  }
  if (nav == null) {
    for (final n in _descendants(navDoc)) {
      if (n.localName == 'nav') {
        nav = n;
        break;
      }
    }
  }
  if (nav == null) return [];
  final navDir = navHref.contains('/')
      ? navHref.substring(0, navHref.lastIndexOf('/') + 1)
      : '';
  final out = <TocEntry>[];

  void walkOl(dom.Element ol, int depth) {
    for (final li in ol.children) {
      if (li.localName != 'li') continue;
      // Donor `:scope > a, :scope > span > a` — first in document order.
      dom.Element? a;
      for (final child in li.children) {
        if (child.localName == 'a') {
          a = child;
          break;
        }
        if (child.localName == 'span') {
          for (final grand in child.children) {
            if (grand.localName == 'a') {
              a = grand;
              break;
            }
          }
          if (a != null) break;
        }
      }
      if (a != null) {
        final href = a.attributes['href'] ?? '';
        final title = a.text.trim().replaceAll(_wsRe, ' ');
        if (title.isNotEmpty) {
          out.add(TocEntry(
              title: title, depth: depth, href: _resolveHref(href, navDir)));
        }
      }
      for (final child in li.children) {
        if (child.localName == 'ol') {
          walkOl(child, depth + 1);
          break; // donor querySelector: first direct-child ol only
        }
      }
    }
  }

  dom.Element? rootOl;
  for (final el in _descendants(nav)) {
    if (el.localName == 'ol') {
      rootOl = el;
      break;
    }
  }
  if (rootOl != null) walkOl(rootOl, 0);
  return out;
}

/// Donor `parseNcxToc`: EPUB2 NCX navMap → entries, nested navPoints one
/// depth deeper.
List<TocEntry> _parseNcxToc(XmlDocument ncxDoc, String ncxHref) {
  final navMap = _firstXml(ncxDoc.rootElement, 'navMap');
  if (navMap == null) return [];
  final ncxDir = ncxHref.contains('/')
      ? ncxHref.substring(0, ncxHref.lastIndexOf('/') + 1)
      : '';
  final out = <TocEntry>[];

  void walk(XmlElement parent, int depth) {
    for (final pt in parent.childElements) {
      if (pt.localName != 'navPoint') continue;
      // Donor querySelector("navLabel > text"): first descendant text whose
      // parent is a navLabel.
      String? labelText;
      for (final el in pt.descendantElements) {
        if (el.localName == 'text' &&
            el.parentElement?.localName == 'navLabel') {
          labelText = el.innerText.trim();
          break;
        }
      }
      String? src;
      for (final el in pt.descendantElements) {
        if (el.localName == 'content') {
          src = el.getAttribute('src');
          break;
        }
      }
      if (labelText != null &&
          labelText.isNotEmpty &&
          src != null &&
          src.isNotEmpty) {
        out.add(TocEntry(
            title: labelText, depth: depth, href: _resolveHref(src, ncxDir)));
      }
      walk(pt, depth + 1);
    }
  }

  walk(navMap, 0);
  return out;
}

/// Donor `findZipImage` (H6): try the resolved path, its percent-decoded
/// form, and leading-slash-stripped variants, then fall back to matching by
/// basename across all entries (covers OPF-root vs zip-root mismatches).
ArchiveFile? _findZipImage(
    Map<String, ArchiveFile> byName, Archive archive, String src) {
  if (src.isEmpty) return null;
  String dec(String s) {
    try {
      return Uri.decodeComponent(s);
    } catch (_) {
      return s;
    }
  }

  final variants = [
    src,
    dec(src),
    src.replaceFirst(RegExp('^/'), ''),
    dec(src).replaceFirst(RegExp('^/'), ''),
  ];
  for (final v in variants) {
    final f = byName[v];
    if (f != null) return f;
  }
  final base = dec(src.split('/').last).toLowerCase();
  if (base.isNotEmpty) {
    for (final f in archive.files) {
      if (f.isFile && f.name.split('/').last.toLowerCase() == base) return f;
    }
  }
  return null;
}

/// Mime for an image: the manifest's media-type when an item's href matches
/// the resolved src, else by extension. (The donor stored typeless blobs;
/// the brief asks for a mime, so this is an intake_core addition.)
String _mimeFor(String src, Map<String, _ManifestItem> manifest) {
  String dec(String s) {
    try {
      return Uri.decodeComponent(s);
    } catch (_) {
      return s;
    }
  }

  for (final m in manifest.values) {
    final href = m.href;
    if (href == null || m.type == null) continue;
    if (href == src || dec(href) == dec(src)) return m.type!;
  }
  final dot = src.lastIndexOf('.');
  if (dot >= 0) {
    final ext = dec(src.substring(dot + 1)).toLowerCase();
    final mime = _extensionMime[ext];
    if (mime != null) return mime;
  }
  return 'application/octet-stream';
}
