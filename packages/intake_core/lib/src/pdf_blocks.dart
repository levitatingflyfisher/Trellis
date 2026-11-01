/// PDF pages to reading blocks (1.6.0, owner: "also read other formats
/// like PDF please").
///
/// A PDF holds no paragraphs, headings or reading order, only characters
/// placed on a page. This rebuilds the three from where the characters
/// sit and how large they are set. Pure Dart: the caller reads the file
/// (PDFium, behind a seam in the app) and hands the pages in.
///
/// What it does not try: tables, footnotes kept apart from the body,
/// vertical text. A page set in more than two columns keeps the order
/// the file gives and is named in [PdfDoc.untrustedPages], so the app
/// can say so instead of presenting a guess as fact.
library;

import 'dart:typed_data';

/// One page as PDFium reports it: its characters in content order, each
/// with a box and a font size. Lengths are PDF points; the origin is the
/// bottom left, so a larger y is higher on the page.
final class PdfPageChars {
  final double width;
  final double height;

  /// UTF-16 code units, one per entry of [boxes] and [sizes].
  final String text;

  /// Four per code unit: left, bottom, right, top.
  final Float32List boxes;

  /// The font size of each code unit.
  final Float32List sizes;

  PdfPageChars({
    required this.width,
    required this.height,
    required this.text,
    required this.boxes,
    required this.sizes,
  })  : assert(boxes.length == text.length * 4),
        assert(sizes.length == text.length);
}

/// A heading or a paragraph, and the page (from 1) it starts on.
final class PdfBlock {
  final bool heading;
  final String text;
  final int page;
  const PdfBlock({required this.heading, required this.text, required this.page});

  @override
  String toString() => 'PdfBlock(${heading ? 'heading' : 'prose'}, p.$page, $text)';
}

final class PdfDoc {
  final String title;
  final List<PdfBlock> blocks;
  final int pageCount;

  /// Pages (from 1) whose reading order could not be worked out; they
  /// keep the order the file gives.
  final List<int> untrustedPages;

  /// Pages (from 1) with no text at all: pictures of pages, or blanks.
  final List<int> textlessPages;

  const PdfDoc({
    required this.title,
    required this.blocks,
    required this.pageCount,
    required this.untrustedPages,
    required this.textlessPages,
  });

  /// False for a file that is only pictures of pages.
  bool get hasText => blocks.isNotEmpty;
}

/// Rebuilds [pages] into headings and paragraphs in reading order.
/// [metaTitle] is the file's own Title field, [sourceName] its file name;
/// both only help to name the work.
PdfDoc pdfToBlocks(List<PdfPageChars> pages,
    {String? metaTitle, String? sourceName}) {
  final pageLines = [for (final p in pages) _linesOf(p)];
  _dropRunningHeads(pages, pageLines);

  final bodySize = _bodySize(pageLines);
  final pageRegions = [
    for (final lines in pageLines)
      lines.isEmpty ? null : _regionsOf(lines, bodySize),
  ];
  final pitchRatio = _typicalPitchRatio(pageRegions);
  final untrusted = <int>[];
  final textless = <int>[];
  final paras = <_Para>[];

  for (var i = 0; i < pages.length; i++) {
    final lines = pageLines[i];
    if (lines.isEmpty) {
      textless.add(i + 1);
      continue;
    }
    final regions = pageRegions[i];
    if (regions == null) {
      untrusted.add(i + 1);
      // The file's own order, each line its own piece: merging is left
      // to the sentence rule below.
      for (final l in lines) {
        _addPara(paras, _Para.of([l], i + 1), carried: true);
      }
      continue;
    }
    for (final region in regions) {
      var first = true;
      for (final group in _paragraphsOf(region, pitchRatio)) {
        _addPara(paras, _Para.of(group, i + 1), carried: first);
        first = false;
      }
    }
  }

  final blocks = <PdfBlock>[
    for (final p in paras)
      if (p.text.isNotEmpty)
        PdfBlock(
            heading: p.size >= bodySize * 1.15 && p.text.length <= 200,
            text: p.text,
            page: p.page),
  ];
  return PdfDoc(
      title: _titleOf(metaTitle, sourceName, blocks),
      blocks: blocks,
      pageCount: pages.length,
      untrustedPages: untrusted,
      textlessPages: textless);
}

// ---------------------------------------------------------------- lines

class _Line {
  _Line(this.size);
  final StringBuffer _text = StringBuffer();
  double left = double.infinity;
  double right = double.negativeInfinity;
  double bottom = double.infinity;
  double top = double.negativeInfinity;
  final double size;
  final List<double> _bottoms = [];
  final Map<double, int> _sizes = {};
  bool _space = false;
  double _lastLeft = 0, _lastRight = 0;

  String get text => _text.toString();
  double get width => right - left;
  double get centerX => (left + right) / 2;
  double get centerY => (bottom + top) / 2;

  /// Where the line sits: the middle glyph foot, which descenders and
  /// commas do not move.
  late final double baseline = () {
    final b = [..._bottoms]..sort();
    return b[b.length ~/ 2];
  }();

  /// The size most of the line is set in.
  late final double mainSize = () {
    var best = size, n = 0;
    _sizes.forEach((s, c) {
      if (c > n) {
        best = s;
        n = c;
      }
    });
    return best;
  }();

  bool get isRtl => _rtl.hasMatch(text);

  bool accepts(double l, double b, double r, double t) {
    final mid = (b + t) / 2;
    if (mid < bottom - size * 0.2 || mid > top + size * 0.2) return false;
    final gap = l > right ? l - right : (r < left ? left - r : 0.0);
    return gap < size * 2;
  }

  void add(String ch, double l, double b, double r, double t, double s) {
    if (_text.isNotEmpty) {
      final gap = l >= _lastRight
          ? l - _lastRight
          : (r <= _lastLeft ? _lastLeft - r : 0.0);
      if (_space || gap > size * 0.3) _text.write(' ');
    }
    _space = false;
    _text.write(ch);
    if (l < left) left = l;
    if (r > right) right = r;
    if (b < bottom) bottom = b;
    if (t > top) top = t;
    _bottoms.add(b);
    _sizes[s] = (_sizes[s] ?? 0) + 1;
    _lastLeft = l;
    _lastRight = r;
  }

  void space() {
    if (_text.isNotEmpty) _space = true;
  }
}

final _rtl = RegExp(r'[֐-ࣿיִ-﷿ﹰ-﻿]');

bool _isSpace(int c) =>
    c == 0x20 || c == 0xA0 || c == 0x09 || (c >= 0x2000 && c <= 0x200A) || c == 0x3000;

/// Not a glyph: controls (PDFium's line ends among them), the marks it
/// leaves for a broken word, and unpaired noncharacters.
bool _isControl(int c) =>
    c < 0x20 || c == 0x7F || c == 0xAD || c == 0xFFFE || c == 0xFFFF || c == 0xFEFF;

List<_Line> _linesOf(PdfPageChars p) {
  final lines = <_Line>[];
  _Line? cur;
  final t = p.text;
  for (var i = 0; i < t.length; i++) {
    final c = t.codeUnitAt(i);
    if (_isControl(c)) continue;
    if (_isSpace(c)) {
      cur?.space();
      continue;
    }
    final l = p.boxes[i * 4], b = p.boxes[i * 4 + 1];
    final r = p.boxes[i * 4 + 2], top = p.boxes[i * 4 + 3];
    // Some files report every font at size 1 and scale the page
    // instead; the glyph's own height stands in.
    var s = p.sizes[i].toDouble();
    if (s < 2) s = (top - b) > 2 ? (top - b) * 1.4 : 10;
    s = (s * 2).roundToDouble() / 2;
    if (cur == null || !cur.accepts(l, b, r, top)) {
      cur = _Line(s);
      lines.add(cur);
    }
    cur.add(String.fromCharCode(c), l, b, r, top, s);
  }
  return lines;
}

// ------------------------------------------------- running heads, feet

final _digits = RegExp(r'\d+');
final _roman = RegExp(r'^[ivxlcdm]+$');

String _headKey(_Line l) {
  final t = l.text.trim().toLowerCase().replaceAll(_digits, '#');
  // The size is part of it: a title set large is not the small running
  // head that repeats its words.
  return '${l.mainSize}|${_roman.hasMatch(t) ? '#' : t}';
}

/// Running heads and feet: what stands in the outermost row of a page,
/// within its top or bottom tenth, and comes back there on three pages
/// or more, or on both pages of a two-page file (page numbers count as
/// the same words). A lone page number there goes on any page.
///
/// Only the outermost row: a body line near the edge of a page with
/// small margins is not a running head because it happens to repeat.
void _dropRunningHeads(List<PdfPageChars> pages, List<List<_Line>> pageLines) {
  List<_Line> edgeLines(int i) {
    final lines = pageLines[i];
    if (lines.isEmpty) return const [];
    var top = double.negativeInfinity, bottom = double.infinity;
    for (final l in lines) {
      if (l.baseline > top) top = l.baseline;
      if (l.baseline < bottom) bottom = l.baseline;
    }
    final h = pages[i].height;
    return [
      for (final l in lines)
        if ((l.baseline > top - 2 && l.centerY > h * 0.9) ||
            (l.baseline < bottom + 2 && l.centerY < h * 0.1))
          l,
    ];
  }

  final edges = [for (var i = 0; i < pages.length; i++) edgeLines(i)];
  final seenOn = <String, int>{};
  for (final lines in edges) {
    for (final k in {for (final l in lines) _headKey(l)}) {
      seenOn[k] = (seenOn[k] ?? 0) + 1;
    }
  }
  // Three pages, or both pages of a file that has only two.
  final often = pages.length == 2 ? 2 : 3;
  final bareNumber = RegExp(r'^[\d.]+\|[\W_]*#[\W_]*$');
  for (var i = 0; i < pages.length; i++) {
    final gone = {
      for (final l in edges[i])
        if ((seenOn[_headKey(l)] ?? 0) >= often ||
            bareNumber.hasMatch(_headKey(l)))
          l,
    };
    pageLines[i].removeWhere(gone.contains);
  }
}

// ------------------------------------------------------- sizes, pitch

double _bodySize(List<List<_Line>> pageLines) {
  final weight = <double, int>{};
  for (final lines in pageLines) {
    for (final l in lines) {
      weight[l.mainSize] = (weight[l.mainSize] ?? 0) + l.text.length;
    }
  }
  var best = 10.0, n = 0;
  weight.forEach((s, c) {
    if (c > n) {
      best = s;
      n = c;
    }
  });
  return best;
}

/// The usual distance from one line to the next, in font sizes: what a
/// paragraph gap has to be clearly wider than. Measured down each
/// region, where one line really does follow the other.
double _typicalPitchRatio(List<List<List<_Line>>?> pageRegions) {
  final ratios = <double>[];
  for (final regions in pageRegions) {
    for (final lines in regions ?? const <List<_Line>>[]) {
      for (var i = 1; i < lines.length; i++) {
        final a = lines[i - 1], b = lines[i];
        final pitch = a.baseline - b.baseline;
        if (a.mainSize == b.mainSize && pitch > 0 && pitch < a.mainSize * 4) {
          ratios.add(pitch / a.mainSize);
        }
      }
    }
  }
  if (ratios.isEmpty) return 1.2;
  ratios.sort();
  return ratios[(ratios.length - 1) ~/ 2];
}

// ----------------------------------------------------- reading order

/// The page's lines as regions in reading order, each a run of lines
/// top to bottom: a line across the page, the left column under it, the
/// right column. Null when the page is set in more than two columns.
List<List<_Line>>? _regionsOf(List<_Line> lines, double bodySize) {
  var minX = double.infinity, maxX = double.negativeInfinity;
  for (final l in lines) {
    if (l.left < minX) minX = l.left;
    if (l.right > maxX) maxX = l.right;
  }
  final extent = maxX - minX;
  bool spans(_Line l) => l.width > extent * 0.55;

  // The stretches of the page's width that narrow lines cover; the gaps
  // between them are gutters.
  final narrow = [for (final l in lines) if (!spans(l)) l]
    ..sort((a, b) => a.left.compareTo(b.left));
  final bands = <({double left, double right, int count})>[];
  for (final l in narrow) {
    if (bands.isNotEmpty && l.left <= bands.last.right + bodySize * 1.5) {
      final last = bands.removeLast();
      bands.add((
        left: last.left,
        right: l.right > last.right ? l.right : last.right,
        count: last.count + 1
      ));
    } else {
      bands.add((left: l.left, right: l.right, count: 1));
    }
  }
  // A band of one line is a stray (a short last line, a caption), not a
  // column.
  final columns = [for (final b in bands) if (b.count >= 2) b];

  int byHeight(_Line a, _Line b) => b.top.compareTo(a.top);
  if (columns.length <= 1) {
    return [[...lines]..sort(byHeight)];
  }
  if (columns.length > 2) return null;

  final gutter = (columns[0].right + columns[1].left) / 2;
  final regions = <List<_Line>>[];
  var left = <_Line>[], right = <_Line>[];
  void flush() {
    if (left.isNotEmpty) regions.add(left);
    if (right.isNotEmpty) regions.add(right);
    left = [];
    right = [];
  }

  for (final l in [...lines]..sort(byHeight)) {
    if (spans(l) || (l.left < gutter && l.right > gutter)) {
      flush();
      regions.add([l]);
    } else {
      (l.centerX < gutter ? left : right).add(l);
    }
  }
  flush();
  return regions;
}

// ---------------------------------------------------------- paragraphs

final _sentenceEnd = RegExp(r'[.!?…:;]["”’»)\]]*$');

/// Splits a region's lines, already top to bottom, into paragraphs.
List<List<_Line>> _paragraphsOf(List<_Line> region, double pitchRatio) {
  var regionLeft = double.infinity, regionRight = double.negativeInfinity;
  for (final l in region) {
    if (l.left < regionLeft) regionLeft = l.left;
    if (l.right > regionRight) regionRight = l.right;
  }
  final regionWidth = regionRight - regionLeft;
  final out = <List<_Line>>[];
  for (final line in region) {
    if (out.isEmpty) {
      out.add([line]);
      continue;
    }
    final prev = out.last.last;
    final size = prev.mainSize;
    final pitch = prev.baseline - line.baseline;
    final resized = (line.mainSize - size).abs() > size * 0.1;
    final gapped = pitch > size * pitchRatio * 1.35;
    // A paragraph's first line is indented at the side reading starts
    // from, and its last line stops short of the other side: left then
    // right for most scripts, mirrored for right-to-left ones.
    final rtl = line.isRtl;
    final indent = rtl ? prev.right - line.right : line.left - prev.left;
    final fromEdge = rtl ? regionRight - line.right : line.left - regionLeft;
    final indented =
        indent > size * 0.8 && fromEdge > size * 0.8 && fromEdge < size * 6;
    final short = prev.isRtl
        ? prev.left > regionLeft + regionWidth * 0.25
        : prev.right < regionRight - regionWidth * 0.25;
    final endedShort = short && _sentenceEnd.hasMatch(prev.text);
    if (resized || gapped || indented || endedShort) {
      out.add([line]);
    } else {
      out.last.add(line);
    }
  }
  return out;
}

class _Para {
  _Para(this.text, this.size, this.page);
  String text;
  final double size;
  final int page;

  factory _Para.of(List<_Line> lines, int page) {
    final b = StringBuffer();
    for (final l in lines) {
      _join(b, l.text);
    }
    return _Para(_tidy(b.toString()), lines.first.mainSize, page);
  }
}

final _startsLower = RegExp(r'^\p{Ll}', unicode: true);
final _brokenWord = RegExp(r'\p{L}[-‐]$', unicode: true);
final _spaces = RegExp(r'\s+');

String _tidy(String s) => s.replaceAll(_spaces, ' ').trim();

/// Adds [next] after what is in [b]: a word broken at the line end is
/// made whole, anything else is a space apart.
void _join(StringBuffer b, String next) {
  final soFar = b.toString();
  final n = next.trim();
  if (n.isEmpty) return;
  if (soFar.isEmpty) {
    b.write(n);
  } else if (_brokenWord.hasMatch(soFar) && _startsLower.hasMatch(n)) {
    b
      ..clear()
      ..write(soFar.substring(0, soFar.length - 1))
      ..write(n);
  } else {
    b
      ..write(' ')
      ..write(n);
  }
}

/// Appends [p]. Where it is [carried] over a break in the layout (a new
/// column, a new page, a page whose order is the file's own) it joins
/// the paragraph before when that one stops mid-sentence and this one
/// goes on in lower case.
void _addPara(List<_Para> paras, _Para p, {required bool carried}) {
  if (p.text.isEmpty) return;
  if (carried && paras.isNotEmpty) {
    final prev = paras.last;
    if (prev.size == p.size &&
        !_sentenceEnd.hasMatch(prev.text) &&
        (_startsLower.hasMatch(p.text) || _brokenWord.hasMatch(prev.text))) {
      final b = StringBuffer(prev.text);
      _join(b, p.text);
      prev.text = b.toString();
      return;
    }
  }
  paras.add(p);
}

// --------------------------------------------------------------- title

final _fileLike = RegExp(
    r'\.(docx?|pdf|rtf|odt|tex|indd|pages|qxd|pptx?|xlsx?|txt|dvi|ps)$',
    caseSensitive: false);

String _titleOf(String? meta, String? sourceName, List<PdfBlock> blocks) {
  var m = (meta ?? '').replaceAll(_spaces, ' ').trim();
  m = m.replaceFirst(RegExp(r'^Microsoft Word - ', caseSensitive: false), '');
  if (m.isNotEmpty &&
      !_fileLike.hasMatch(m) &&
      m.toLowerCase() != 'untitled') {
    return m;
  }
  for (final b in blocks) {
    if (b.page != 1) break;
    if (b.heading) return b.text;
  }
  final name = (sourceName ?? '').trim();
  if (name.isNotEmpty) {
    final dot = name.lastIndexOf('.');
    final bare = dot > 0 ? name.substring(0, dot) : name;
    if (bare.trim().isNotEmpty) return bare.trim();
  }
  return 'Untitled PDF';
}
