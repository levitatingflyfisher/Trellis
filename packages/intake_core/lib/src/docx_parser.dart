/// Word documents (.docx) as reading text (owner, 17 Nov 2026: "Trellis
/// opens .docx files directly").
///
/// A .docx is a zip of XML parts. This reads the main document part and
/// the parts it names (styles, numbering, footnotes, endnotes, links) and
/// keeps what a reader reads:
///
///  * a paragraph is prose; one whose style is a heading (by its name,
///    its base style or its outline level, so a German "Überschrift 1"
///    counts) is a heading with its level;
///  * a list item carries its bullet or its number ("1.", "a)");
///  * a footnote mark is a raised number (read aloud skips raised marks),
///    and the notes follow their chapter under "Notes". Numbers start
///    afresh in each chapter when the document restarts them in each
///    section, as Word books with a chapter a section do; otherwise they
///    run straight through, so "supra note 4" still finds note 4;
///  * a web link keeps its words and its address;
///  * a table reads a row at a time, each cell under its column, the way
///    Markdown tables do; a one-column table is a layout box, read as
///    prose;
///  * a text box is read once, after its paragraph.
///
/// Left out: the printed table of contents, deleted (tracked) text,
/// hidden text, field codes, and pictures without a description.
library;

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'blocks.dart';

/// What a .docx may declare, uncompressed, before nothing is read.
const maxDocxUncompressedBytes = 200 * 1024 * 1024;

/// A .docx whose contents declare more than [maxDocxUncompressedBytes].
class DocxTooLargeException extends FormatException {
  const DocxTooLargeException()
      : super('That document is too large to open here.');
}

/// A parsed Word document: its title and its blocks in reading order.
final class DocxDoc {
  final String title;
  final List<IntakeBlock> blocks;
  const DocxDoc({required this.title, required this.blocks});
}

const _notWord = FormatException(
    'That file isn’t a Word document Trellis can read. Trellis reads .docx; '
    'an older .doc can be saved as .docx from Word or LibreOffice.');

const _relNs =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

const _raisedDigits = ['⁰', '¹', '²', '³', '⁴', '⁵', '⁶', '⁷', '⁸', '⁹'];

String _raised(int n) =>
    n.toString().split('').map((d) => _raisedDigits[int.parse(d)]).join();

/// Reads [bytes] as a .docx. [sourceName] names it when the document
/// does not. Throws [FormatException] when it is not one, and
/// [DocxTooLargeException] over [maxUncompressedBytes].
DocxDoc parseDocx(List<int> bytes,
    {String? sourceName, int maxUncompressedBytes = maxDocxUncompressedBytes}) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw _notWord;
  }
  var declared = 0;
  for (final f in archive.files) {
    if (f.isFile) declared += f.size;
  }
  if (declared > maxUncompressedBytes) throw const DocxTooLargeException();
  final byName = <String, ArchiveFile>{
    for (final f in archive.files)
      if (f.isFile) f.name: f,
  };
  XmlDocument? part(String? name) {
    final f = name == null ? null : byName[name];
    if (f == null) return null;
    try {
      return XmlDocument.parse(utf8.decode(f.content, allowMalformed: true));
    } on XmlException {
      return null;
    }
  }

  final rootRels = _rels(part('_rels/.rels'), '');
  final mainName = rootRels.byType('officeDocument') ?? 'word/document.xml';
  final main = part(mainName);
  final body = main == null ? null : _child(main.rootElement, 'body');
  if (body == null) throw _notWord;

  final dir = mainName.contains('/')
      ? mainName.substring(0, mainName.lastIndexOf('/') + 1)
      : '';
  String relsOf(String name) {
    final slash = name.lastIndexOf('/');
    return '${name.substring(0, slash + 1)}_rels/${name.substring(slash + 1)}.rels';
  }

  final docRels = _rels(part(relsOf(mainName)), dir);
  final styles = _Styles(part(docRels.byType('styles')));
  final numbering = _Numbering(part(docRels.byType('numbering')));

  final notes = <String, _Para>{};
  for (final kind in const ['footnotes', 'endnotes']) {
    final name = docRels.byType(kind);
    final xml = part(name);
    if (name == null || xml == null) continue;
    final rels = _rels(part(relsOf(name)), dir);
    for (final n in xml.rootElement.childElements) {
      if (n.name.local != 'footnote' && n.name.local != 'endnote') continue;
      final type = _attr(n, 'type');
      if (type != null && type != 'normal') continue;
      final id = _attr(n, 'id');
      if (id == null) continue;
      final joined = _Para();
      for (final p in n.findAllElements('p', namespace: '*')) {
        final one = _Para();
        _Walker(rels, null, one).walk(p);
        joined.append(one);
      }
      notes['${n.name.local == 'endnote' ? 'e' : 'f'}$id'] = joined;
    }
  }

  final settings = part(docRels.byType('settings'));
  final restart = [main!, if (settings != null) settings].any((x) => x
      .findAllElements('numRestart', namespace: '*')
      .any((e) => _attr(e, 'val') != 'continuous'));

  // The paragraphs and tables in order, each classified once.
  final items = <_Item>[];
  final fields = _Fields();
  void collect(XmlElement parent) {
    for (final e in parent.childElements) {
      switch (e.name.local) {
        case 'p':
          // Walked even when it is left out: a table of contents is a
          // field, and its end may share a paragraph with the first
          // heading after it.
          final para = _Para();
          final boxes = <XmlElement>[];
          _Walker(docRels, boxes, para, fields).walk(e);
          final style = _pStyle(e);
          if (styles.isToc(style)) continue;
          final level = _outlineLevel(e) ?? styles.headingLevel(style);
          if (level == null) {
            final prefix = numbering.prefixFor(e);
            if (prefix != null && para.text.isNotEmpty) para.prefix('$prefix ');
          }
          items.add(_Item.para(para, level, styles.isTitle(style)));
          for (final box in boxes) {
            collect(box);
          }
        case 'tbl':
          items.addAll(_table(e, docRels));
        case 'sdt':
          final content = _child(e, 'sdtContent');
          if (content != null) collect(content);
        case 'customXml' || 'ins' || 'moveTo':
          collect(e);
      }
    }
  }

  collect(body);

  // Title: the document's own, else a Title paragraph before any text,
  // else the file's name.
  var title = '';
  final core = part(rootRels.byType('core-properties') ?? 'docProps/core.xml');
  if (core != null) {
    title = core.rootElement.childElements
            .where((e) => e.name.local == 'title')
            .firstOrNull
            ?.innerText
            .trim() ??
        '';
  }
  final leading = items.where((i) => i.para?.text.isNotEmpty ?? true).firstOrNull;
  if (title.isEmpty && leading != null && leading.isTitle) {
    title = leading.para!.text;
    items.remove(leading);
  }
  if (title.isEmpty && sourceName != null) {
    title = sourceName.replaceAll(RegExp(r'\.docx$', caseSensitive: false), '').trim();
  }
  if (title.isEmpty) title = 'Untitled';

  final headingLevels = [
    for (final i in items)
      if (i.para != null && i.para!.text.isNotEmpty && i.level != null) i.level!,
  ];
  final chapterLevel = headingLevels.isEmpty
      ? 1
      : headingLevels.reduce((a, b) => a < b ? a : b);
  // Notes sit under their chapter; with no chapters, at the top.
  final notesLevel = headingLevels.isEmpty ? 1 : chapterLevel + 1;

  final blocks = <IntakeBlock>[];
  var counter = 0;
  final pending = <(int, _Para)>[];
  void flushNotes() {
    if (pending.isEmpty) return;
    blocks.add(HeadingBlock('Notes', level: notesLevel));
    for (final (n, note) in pending) {
      final copy = _Para()..append(note);
      copy.prefix('${_raised(n)} ');
      blocks.add(copy.block);
    }
    pending.clear();
  }

  for (final item in items) {
    if (item.table != null) {
      blocks.addAll(item.table!);
      continue;
    }
    final para = item.para!;
    if (para.text.isEmpty) continue;
    final level = item.level;
    if (level != null) {
      if (level <= chapterLevel) {
        flushNotes();
        if (restart) counter = 0;
      }
      blocks.add(HeadingBlock(para.text, level: level));
      continue;
    }
    blocks.add(para.resolve((key) {
      final note = notes[key];
      if (note == null || note.text.isEmpty) return null;
      counter++;
      pending.add((counter, note));
      return _raised(counter);
    }));
  }
  flushNotes();
  return DocxDoc(title: title, blocks: blocks);
}

XmlElement? _child(XmlElement e, String local) =>
    e.childElements.where((c) => c.name.local == local).firstOrNull;

/// A w: attribute by its local name.
String? _attr(XmlElement e, String local) {
  for (final a in e.attributes) {
    if (a.name.local == local) return a.value;
  }
  return null;
}

String? _pStyle(XmlElement p) {
  final ppr = _child(p, 'pPr');
  final s = ppr == null ? null : _child(ppr, 'pStyle');
  return s == null ? null : _attr(s, 'val');
}

int? _outlineLevel(XmlElement p) {
  final ppr = _child(p, 'pPr');
  final o = ppr == null ? null : _child(ppr, 'outlineLvl');
  final v = o == null ? null : int.tryParse(_attr(o, 'val') ?? '');
  return v == null || v > 8 ? null : v + 1;
}

class _Rels {
  final Map<String, String> byId;
  final Map<String, String> typed;
  const _Rels(this.byId, this.typed);

  String? byType(String suffix) => typed[suffix];
}

/// A part's relationships: [_Rels.byId] holds external web links;
/// [_Rels.typed] the internal parts by the end of their type, as paths
/// from the zip's root.
_Rels _rels(XmlDocument? xml, String dir) {
  final byId = <String, String>{};
  final typed = <String, String>{};
  if (xml == null) return _Rels(byId, typed);
  for (final r in xml.rootElement.childElements) {
    final id = r.getAttribute('Id');
    final target = r.getAttribute('Target');
    final type = r.getAttribute('Type') ?? '';
    if (id == null || target == null) continue;
    if (r.getAttribute('TargetMode') == 'External') {
      final uri = Uri.tryParse(target.trim());
      if (uri != null &&
          (uri.scheme == 'http' || uri.scheme == 'https') &&
          uri.host.isNotEmpty) {
        byId[id] = uri.toString();
      }
      continue;
    }
    final name = target.startsWith('/')
        ? target.substring(1)
        : _normalize('$dir$target');
    typed[type.substring(type.lastIndexOf('/') + 1)] = name;
  }
  return _Rels(byId, typed);
}

String _normalize(String path) {
  final out = <String>[];
  for (final s in path.split('/')) {
    if (s == '..') {
      if (out.isNotEmpty) out.removeLast();
    } else if (s.isNotEmpty && s != '.') {
      out.add(s);
    }
  }
  return out.join('/');
}

class _Styles {
  final _name = <String, String>{};
  final _basedOn = <String, String>{};
  final _outline = <String, int>{};

  _Styles(XmlDocument? xml) {
    if (xml == null) return;
    for (final s in xml.rootElement.childElements) {
      if (s.name.local != 'style') continue;
      final id = _attr(s, 'styleId');
      if (id == null) continue;
      final name = _child(s, 'name');
      if (name != null) _name[id] = (_attr(name, 'val') ?? '').toLowerCase();
      final based = _child(s, 'basedOn');
      if (based != null && _attr(based, 'val') != null) {
        _basedOn[id] = _attr(based, 'val')!;
      }
      final ppr = _child(s, 'pPr');
      final o = ppr == null ? null : _child(ppr, 'outlineLvl');
      final v = o == null ? null : int.tryParse(_attr(o, 'val') ?? '');
      if (v != null && v <= 8) _outline[id] = v + 1;
    }
  }

  /// [id] and its base styles, nearest first.
  Iterable<String> _chain(String? id) sync* {
    final seen = <String>{};
    while (id != null && seen.add(id)) {
      yield id;
      id = _basedOn[id];
    }
  }

  static final _headingName = RegExp(r'^heading (\d)$');

  int? headingLevel(String? id) {
    for (final s in _chain(id)) {
      if (_outline.containsKey(s)) return _outline[s];
      final m = _headingName.firstMatch(_name[s] ?? '');
      if (m != null) return int.parse(m.group(1)!);
      if (_name[s] == 'title' || (_name[s] == null && s == 'Title')) return 1;
      if (_name[s] == null) {
        final byId = RegExp(r'^Heading(\d)$').firstMatch(s);
        if (byId != null) return int.parse(byId.group(1)!);
      }
    }
    return null;
  }

  bool isTitle(String? id) =>
      _chain(id).any((s) => _name[s] == 'title' || (_name[s] == null && s == 'Title'));

  bool isToc(String? id) => _chain(id).any((s) =>
      (_name[s] ?? '').startsWith('toc ') ||
      _name[s] == 'toc heading' ||
      (_name[s] == null && RegExp(r'^TOC\d?$').hasMatch(s)));
}

class _Numbering {
  /// numId → ilvl → (format, start, text).
  final _levels = <String, Map<int, (String, int, String)>>{};
  final _counters = <String, Map<int, int>>{};

  _Numbering(XmlDocument? xml) {
    if (xml == null) return;
    final abstract = <String, Map<int, (String, int, String)>>{};
    for (final a in xml.rootElement.childElements) {
      if (a.name.local != 'abstractNum') continue;
      final id = _attr(a, 'abstractNumId');
      if (id == null) continue;
      final levels = <int, (String, int, String)>{};
      for (final l in a.childElements.where((e) => e.name.local == 'lvl')) {
        final ilvl = int.tryParse(_attr(l, 'ilvl') ?? '');
        if (ilvl == null) continue;
        String val(String local) {
          final e = _child(l, local);
          return e == null ? '' : _attr(e, 'val') ?? '';
        }

        levels[ilvl] =
            (val('numFmt'), int.tryParse(val('start')) ?? 1, val('lvlText'));
      }
      abstract[id] = levels;
    }
    for (final n in xml.rootElement.childElements) {
      if (n.name.local != 'num') continue;
      final id = _attr(n, 'numId');
      final ref = _child(n, 'abstractNumId');
      final levels = ref == null ? null : abstract[_attr(ref, 'val')];
      if (id != null && levels != null) _levels[id] = levels;
    }
  }

  /// The mark a list paragraph shows, counting it; null when [p] is not a
  /// list item.
  String? prefixFor(XmlElement p) {
    final ppr = _child(p, 'pPr');
    final num = ppr == null ? null : _child(ppr, 'numPr');
    if (num == null) return null;
    final idEl = _child(num, 'numId');
    final id = idEl == null ? null : _attr(idEl, 'val');
    if (id == null || id == '0') return null;
    final lvlEl = _child(num, 'ilvl');
    final ilvl = int.tryParse((lvlEl == null ? null : _attr(lvlEl, 'val')) ?? '0') ?? 0;
    final levels = _levels[id];
    final level = levels?[ilvl];
    if (levels == null || level == null) return '•';
    final (fmt, _, text) = level;
    if (fmt == 'bullet' || fmt == 'none' || fmt.isEmpty) return '•';
    final counts = _counters.putIfAbsent(id, () => {});
    counts[ilvl] = (counts[ilvl] ?? (level.$2 - 1)) + 1;
    counts.removeWhere((k, _) => k > ilvl);
    final out = text.replaceAllMapped(RegExp(r'%(\d)'), (m) {
      final l = int.parse(m.group(1)!) - 1;
      final spec = levels[l];
      final n = counts[l] ?? spec?.$2 ?? 1;
      return _format(spec?.$1 ?? 'decimal', n);
    }).trim();
    return out.isEmpty ? '•' : out;
  }

  static String _format(String fmt, int n) => switch (fmt) {
        'lowerLetter' => _letters(n),
        'upperLetter' => _letters(n).toUpperCase(),
        'lowerRoman' => _roman(n).toLowerCase(),
        'upperRoman' => _roman(n),
        _ => '$n',
      };

  static String _letters(int n) {
    if (n < 1) return '$n';
    final letter = String.fromCharCode(0x61 + (n - 1) % 26);
    return letter * ((n - 1) ~/ 26 + 1);
  }

  static String _roman(int n) {
    if (n < 1 || n > 3999) return '$n';
    const v = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
    const s = ['M', 'CM', 'D', 'CD', 'C', 'XC', 'L', 'XL', 'X', 'IX', 'V', 'IV', 'I'];
    final out = StringBuffer();
    for (var i = 0; i < v.length; i++) {
      while (n >= v[i]) {
        out.write(s[i]);
        n -= v[i];
      }
    }
    return out.toString();
  }
}

/// A paragraph's text as it is built: whitespace folded as it arrives,
/// so link offsets need no fixing afterwards. Footnote marks wait as
/// placeholders until [resolve] numbers them in reading order.
class _Para {
  final _buf = StringBuffer();
  bool _endsInSpace = false;
  final links = <TextLink>[];

  /// (offset in the text, note key), in order.
  final marks = <(int, String)>[];

  String get text => _buf.toString().trimRight();

  void add(String s) {
    for (final rune in s.runes) {
      final c = String.fromCharCode(rune);
      if (c.trim().isEmpty) {
        if (_buf.isNotEmpty && !_endsInSpace) {
          _buf.write(' ');
          _endsInSpace = true;
        }
      } else {
        _buf.write(c);
        _endsInSpace = false;
      }
    }
  }

  int get length => _buf.length;

  void mark(String key) => marks.add((_buf.length, key));

  void link(int start, String href) {
    final end = text.length;
    if (end > start) links.add(TextLink(start: start, end: end, href: href));
  }

  void append(_Para other) {
    final t = other.text;
    if (t.isEmpty) return;
    if (_buf.isNotEmpty && !_endsInSpace) _buf.write(' ');
    final shift = _buf.length;
    _buf.write(t);
    _endsInSpace = false;
    for (final l in other.links) {
      links.add(TextLink(start: l.start + shift, end: l.end + shift, href: l.href));
    }
    for (final (at, key) in other.marks) {
      marks.add((at + shift, key));
    }
  }

  void prefix(String p) {
    final t = _buf.toString();
    _buf
      ..clear()
      ..write(p)
      ..write(t);
    for (var i = 0; i < links.length; i++) {
      final l = links[i];
      links[i] = TextLink(start: l.start + p.length, end: l.end + p.length, href: l.href);
    }
    for (var i = 0; i < marks.length; i++) {
      marks[i] = (marks[i].$1 + p.length, marks[i].$2);
    }
  }

  TextBlock get block {
    final t = text;
    return TextBlock(t, links: [
      for (final l in links)
        if (l.end <= t.length) l
    ]);
  }

  /// The text with each mark replaced by what [number] gives it (a mark
  /// with no note gives null and leaves nothing).
  TextBlock resolve(String? Function(String key) number) {
    if (marks.isEmpty) return block;
    final t = text;
    final out = StringBuffer();
    var from = 0;
    final inserts = <(int, int)>[]; // (at, length) in the old text
    for (final (at, key) in marks) {
      final pos = at > t.length ? t.length : at;
      out.write(t.substring(from, pos));
      final n = number(key);
      if (n != null) {
        out.write(n);
        inserts.add((pos, n.length));
      }
      from = pos;
    }
    out.write(t.substring(from));
    // A mark where a link starts goes before it; one where it ends, after.
    int shifted(int i, {required bool end}) {
      var s = i;
      for (final (at, len) in inserts) {
        if (end ? at < i : at <= i) s += len;
      }
      return s;
    }

    return TextBlock(out.toString(), links: [
      for (final l in links)
        if (l.end <= t.length)
          TextLink(
              start: shifted(l.start, end: false),
              end: shifted(l.end, end: true),
              href: l.href)
    ]);
  }
}

/// The fields open at a point in the body, by their instructions, so a
/// table of contents is known across all its paragraphs.
class _Fields {
  final _open = <StringBuffer>[];

  bool get inToc =>
      _open.any((f) => f.toString().trimLeft().toUpperCase().startsWith('TOC'));

  void char(XmlElement e) {
    switch (_attr(e, 'fldCharType')) {
      case 'begin':
        _open.add(StringBuffer());
      case 'end':
        if (_open.isNotEmpty) _open.removeLast();
    }
  }

  void instruction(XmlElement e) {
    if (_open.isNotEmpty) _open.last.write(e.innerText);
  }
}

/// Walks one paragraph's runs into a [_Para].
class _Walker {
  final _Rels rels;

  /// Text boxes met on the way, read after the paragraph; null inside a
  /// note or a table cell, where a box is read in place.
  final List<XmlElement>? boxes;
  final _Para out;

  /// The fields open around this text: the body's, carried from
  /// paragraph to paragraph, or a fresh one for a note or a cell.
  final _Fields fields;
  _Walker(this.rels, this.boxes, this.out, [_Fields? fields])
      : fields = fields ?? _Fields();

  void walk(XmlElement e) {
    for (final c in e.childElements) {
      _node(c);
    }
  }

  void _node(XmlElement e) {
    switch (e.name.local) {
      case 't':
        if (!fields.inToc) out.add(e.innerText);
      case 'fldChar':
        fields.char(e);
      case 'instrText':
        fields.instruction(e);
      case 'tab' || 'ptab' || 'br' || 'cr':
        out.add(' ');
      case 'noBreakHyphen':
        out.add('-');
      case 'footnoteReference':
        final id = _attr(e, 'id');
        if (id != null) out.mark('f$id');
      case 'endnoteReference':
        final id = _attr(e, 'id');
        if (id != null) out.mark('e$id');
      case 'r':
        final rpr = _child(e, 'rPr');
        if (rpr != null && _child(rpr, 'vanish') != null) return;
        walk(e);
      case 'hyperlink':
        final start = out.length;
        walk(e);
        final id = e.getAttribute('id', namespace: _relNs) ?? _attr(e, 'id');
        final href = id == null ? null : rels.byId[id];
        if (href != null) out.link(start, href);
      case 'AlternateContent':
        final choice = _child(e, 'Choice') ?? _child(e, 'Fallback');
        if (choice != null) walk(choice);
      case 'txbxContent':
        if (boxes != null) {
          boxes!.add(e);
        } else {
          for (final p in e.childElements.where((c) => c.name.local == 'p')) {
            out.add(' ');
            walk(p);
          }
        }
      case 'pPr' ||
            'rPr' ||
            'del' ||
            'moveFrom' ||
            'delText' ||
            'delInstrText' ||
            'footnoteRef' ||
            'endnoteRef' ||
            'commentReference' ||
            'annotationRef' ||
            'sym' ||
            'softHyphen' ||
            'separator' ||
            'continuationSeparator':
        return;
      default:
        walk(e);
    }
  }
}

class _Item {
  final _Para? para;
  final int? level;
  final bool isTitle;
  final List<IntakeBlock>? table;
  _Item.para(this.para, this.level, this.isTitle) : table = null;
  _Item.table(this.table)
      : para = null,
        level = null,
        isTitle = false;
}

/// A table as items: a row at a time, each cell under its column head;
/// a one-column table's paragraphs as prose.
List<_Item> _table(XmlElement tbl, _Rels rels) {
  final rows = <List<String>>[];
  for (final tr in tbl.childElements.where((e) => e.name.local == 'tr')) {
    final cells = <String>[];
    for (final tc in tr.childElements.where((e) => e.name.local == 'tc')) {
      final cell = _Para();
      for (final p in tc.findAllElements('p', namespace: '*')) {
        final one = _Para();
        _Walker(rels, null, one).walk(p);
        cell.append(one);
      }
      cells.add(cell.text);
    }
    if (cells.any((c) => c.isNotEmpty)) rows.add(cells);
  }
  if (rows.isEmpty) return const [];
  final width = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
  if (width == 1 || rows.length == 1) {
    return [
      for (final r in rows)
        for (final c in r)
          if (c.isNotEmpty) _Item.table([TextBlock(c)])
    ];
  }
  final heads = rows.first;
  return [
    for (final r in rows.skip(1))
      if (r.any((c) => c.isNotEmpty))
        _Item.table([
          TextBlock(() {
            final row = [
              for (var c = 0; c < r.length; c++)
                if (r[c].isNotEmpty)
                  c < heads.length && heads[c].isNotEmpty
                      ? '${heads[c]}: ${r[c]}'
                      : r[c],
            ].join('; ');
            return RegExp(r'[.!?…]$').hasMatch(row) ? row : '$row.';
          }())
        ])
  ];
}
