/// Markdown as reading text (owner, 1.6.x: "tried to open a markdown file
/// in Trellis and could not").
///
/// The text parser Trellis inherited knows no Markdown: a `#` heading, a
/// list mark or a link's brackets all reach the page, and the voice, as
/// they were typed. This reads a Markdown file for what it says:
///
///  * headings (hash or underlined) become headings, so they are the
///    work's chapters;
///  * a link keeps its words and its address: `[tides](https://x)` reads
///    "tides (https://x)", and the reader and read aloud already know
///    what to do with a bare address;
///  * each list item is a line of its own with a plain mark, and each
///    table row one sentence of "Column: value" pairs, so both read well
///    by eye and by ear;
///  * bold, italics, strike, code marks, HTML tags and comments go;
///  * fenced code is kept exactly, as code, which is shown but not read.
///
/// It is a reader for people's notes and articles, not a CommonMark
/// engine: indented code blocks are read as text (indented text under a
/// list item is far more common), and nested structure is flattened.
library;

enum MarkdownKind { heading, prose, code }

final class MarkdownBlock {
  final MarkdownKind kind;
  final String text;

  /// 1 to 6 for a heading; 0 otherwise.
  final int level;
  const MarkdownBlock(this.kind, this.text, {this.level = 0});

  @override
  String toString() => 'MarkdownBlock(${kind.name}, $text)';
}

final class MarkdownDoc {
  final String title;
  final List<MarkdownBlock> blocks;
  const MarkdownDoc({required this.title, required this.blocks});
}

final _invisible = RegExp(r'[﻿​‌‍⁠­]');
final _lineEnd = RegExp(r'\r\n?|\n');
final _comment = RegExp(r'<!--.*?-->', dotAll: true);
final _refDef =
    RegExp(r'^\s{0,3}\[([^\]\^][^\]]*)\]:\s*<?([^\s>]+)>?(?:\s+.*)?$');
final _footnoteDef = RegExp(r'^\s{0,3}\[\^[^\]]+\]:\s*(.*)$');
final _fence = RegExp(r'^\s{0,3}(`{3,}|~{3,})');
final _atx = RegExp(r'^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$');
final _setext = RegExp(r'^\s{0,3}(=+|-+)\s*$');
final _rule = RegExp(r'^\s{0,3}([-*_])(\s*\1){2,}\s*$');
final _tableRule =
    RegExp(r'^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$');
final _item = RegExp(r'^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$');
final _task = RegExp(r'^\[([ xX])\]\s+(.*)$');
final _quote = RegExp(r'^\s{0,3}>\s?');
final _spaces = RegExp(r'\s+');

/// Reads [source] as Markdown. [sourceName] is the file's name, used
/// only to name the work when the text does not name itself.
MarkdownDoc parseMarkdown(String source, {String? sourceName}) {
  final lines = source
      .replaceAll(_invisible, '')
      .replaceAll(_comment, '')
      .split(_lineEnd);

  // Front matter: a first line of ---, up to the next --- or ...
  String? frontTitle;
  var start = 0;
  if (lines.isNotEmpty && lines.first.trim() == '---') {
    for (var i = 1; i < lines.length; i++) {
      final t = lines[i].trim();
      if (t == '---' || t == '...') {
        start = i + 1;
        break;
      }
      final m = RegExp(r'^title:\s*(.+)$', caseSensitive: false).firstMatch(t);
      if (m != null) frontTitle = _unquote(m.group(1)!.trim());
    }
    if (start == 0) frontTitle = null; // never closed: it is just text
  }

  // Link definitions are looked up, and are not text.
  final refs = <String, String>{};
  final body = <String>[];
  var fenced = false;
  for (final line in lines.skip(start)) {
    if (_fence.hasMatch(line)) fenced = !fenced;
    final def = fenced ? null : _refDef.firstMatch(line);
    if (def != null) {
      refs[def.group(1)!.trim().toLowerCase()] = def.group(2)!;
    } else {
      body.add(line);
    }
  }

  final blocks = <MarkdownBlock>[];
  final para = <String>[];
  String? itemMark; // set while a list item is being gathered
  var itemDone = false;
  var paraPrefix = '';
  var quoted = false;

  void flush() {
    final text = _inline(para.join(' '), refs);
    if (text.isNotEmpty) {
      blocks.add(MarkdownBlock(MarkdownKind.prose,
          '${itemMark ?? paraPrefix}$text${itemDone ? ' (done)' : ''}'));
    }
    para.clear();
    itemMark = null;
    itemDone = false;
    paraPrefix = '';
  }

  for (var i = 0; i < body.length; i++) {
    var line = body[i];

    // Fenced code: kept exactly, to the closing fence.
    final fence = _fence.firstMatch(line);
    if (fence != null) {
      flush();
      final mark = fence.group(1)!;
      final code = <String>[];
      for (i++; i < body.length; i++) {
        final t = body[i].trimLeft();
        if (t.startsWith(mark[0] * mark.length) &&
            t.replaceAll(mark[0], '').trim().isEmpty) {
          break;
        }
        code.add(body[i]);
      }
      if (code.any((l) => l.trim().isNotEmpty)) {
        blocks.add(MarkdownBlock(MarkdownKind.code, code.join('\n')));
      }
      continue;
    }

    // A quote is its words; where one starts or ends, so does a paragraph.
    var isQuote = false;
    while (_quote.hasMatch(line)) {
      line = line.replaceFirst(_quote, '');
      isQuote = true;
    }
    if (isQuote != quoted && line.trim().isNotEmpty) {
      flush();
      quoted = isQuote;
    }

    if (line.trim().isEmpty) {
      flush();
      continue;
    }

    final atx = _atx.firstMatch(line);
    if (atx != null) {
      flush();
      final text = _inline(atx.group(2)!, refs);
      if (text.isNotEmpty) {
        blocks.add(MarkdownBlock(MarkdownKind.heading, text,
            level: atx.group(1)!.length));
      }
      continue;
    }

    // An underline makes the paragraph above it a heading.
    final under = _setext.firstMatch(line);
    if (under != null && para.isNotEmpty && itemMark == null) {
      final text = _inline(para.join(' '), refs);
      para.clear();
      paraPrefix = '';
      if (text.isNotEmpty) {
        blocks.add(MarkdownBlock(MarkdownKind.heading, text,
            level: under.group(1)!.startsWith('=') ? 1 : 2));
      }
      continue;
    }

    if (_rule.hasMatch(line)) {
      flush();
      continue;
    }

    // A table: a row of cells with a row of dashes under it.
    if (line.contains('|') &&
        i + 1 < body.length &&
        body[i + 1].contains('-') &&
        body[i + 1].contains('|') &&
        _tableRule.hasMatch(body[i + 1])) {
      flush();
      final heads = _cells(line, refs);
      for (i += 2; i < body.length; i++) {
        if (body[i].trim().isEmpty || !body[i].contains('|')) break;
        final cells = _cells(body[i], refs);
        final parts = <String>[
          for (var c = 0; c < cells.length; c++)
            if (cells[c].isNotEmpty)
              c < heads.length && heads[c].isNotEmpty
                  ? '${heads[c]}: ${cells[c]}'
                  : cells[c],
        ];
        if (parts.isEmpty) continue;
        final row = parts.join('; ');
        blocks.add(MarkdownBlock(MarkdownKind.prose,
            RegExp(r'[.!?…]$').hasMatch(row) ? row : '$row.'));
      }
      i--;
      continue;
    }

    final note = _footnoteDef.firstMatch(line);
    if (note != null) {
      flush();
      paraPrefix = 'Note: ';
      para.add(note.group(1)!);
      continue;
    }

    final item = _item.firstMatch(line);
    if (item != null) {
      flush();
      final mark = item.group(2)!;
      var text = item.group(3)!;
      final task = _task.firstMatch(text);
      if (task != null) {
        text = task.group(2)!;
        itemDone = task.group(1) != ' ';
      }
      // "1)" not "1.": a number and a full stop would read as a
      // sentence of its own.
      itemMark = RegExp(r'^\d').hasMatch(mark)
          ? '${mark.substring(0, mark.length - 1)}) '
          : '• ';
      para.add(text);
      continue;
    }

    para.add(line.trim());
  }
  flush();

  return MarkdownDoc(
      title: _titleOf(frontTitle, blocks, sourceName), blocks: blocks);
}

String _unquote(String s) =>
    s.length >= 2 &&
            ((s.startsWith('"') && s.endsWith('"')) ||
                (s.startsWith("'") && s.endsWith("'")))
        ? s.substring(1, s.length - 1).trim()
        : s;

String _titleOf(String? front, List<MarkdownBlock> blocks, String? sourceName) {
  if (front != null && front.isNotEmpty) return front;
  MarkdownBlock? first;
  for (final b in blocks) {
    if (b.kind != MarkdownKind.heading) continue;
    if (b.level == 1) return b.text;
    first ??= b;
  }
  if (first != null) return first.text;
  final name = (sourceName ?? '').trim();
  if (name.isNotEmpty) {
    final dot = name.lastIndexOf('.');
    final bare = (dot > 0 ? name.substring(0, dot) : name).trim();
    if (bare.isNotEmpty) return bare;
  }
  return 'Untitled';
}

List<String> _cells(String row, Map<String, String> refs) {
  var r = row.trim();
  if (r.startsWith('|')) r = r.substring(1);
  if (r.endsWith('|') && !r.endsWith(r'\|')) r = r.substring(0, r.length - 1);
  return [
    for (final c in r.split(RegExp(r'(?<!\\)\|')))
      _inline(c.replaceAll(r'\|', '|'), refs),
  ];
}

final _codeSpan = RegExp(r'(`+)(.+?)\1');
final _escape = RegExp(r'\\([\\`*_{}\[\]()#+\-.!|~>])');
final _image = RegExp(r'!\[([^\]]*)\]\([^)]*\)');
final _link = RegExp(
    r'''\[([^\]]+)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*"|\s+'[^']*')?\s*\)''');
final _refLink = RegExp(r'\[([^\]]+)\]\[([^\]]*)\]');
final _footnoteRef = RegExp(r'\[\^[^\]]+\]');
final _autolink = RegExp(r'<((?:https?://|mailto:)[^>\s]+|[^\s<>@]+@[^\s<>@]+)>');
final _lineBreakTag = RegExp(r'<br\s*/?>', caseSensitive: false);
final _tag = RegExp(r'</?[A-Za-z][^>]*>');
final _strong = RegExp(r'\*\*(?=\S)(.+?)(?<=\S)\*\*');
final _strongUnder = RegExp(
    r'(?<![\p{L}\p{N}_])__(?=\S)(.+?)(?<=\S)__(?![\p{L}\p{N}_])',
    unicode: true);
final _em = RegExp(r'\*(?=\S)(.+?)(?<=\S)\*');
final _emUnder = RegExp(
    r'(?<![\p{L}\p{N}_])_(?=\S)(.+?)(?<=\S)_(?![\p{L}\p{N}_])',
    unicode: true);
final _strike = RegExp(r'~~(?=\S)(.+?)(?<=\S)~~');
final _held = RegExp('\u0000(\\d+)\u0000');

/// One line's words without its markup.
String _inline(String text, Map<String, String> refs) {
  // What must come through untouched (code, escaped marks) is set aside
  // first and put back last.
  final kept = <String>[];
  String hold(String s) {
    kept.add(s);
    return '\u0000${kept.length - 1}\u0000';
  }

  String linked(String words, String url) {
    final w = words.trim();
    return w.isEmpty || w == url ? hold(url) : '$w (${hold(url)})';
  }

  var t = text
      .replaceAllMapped(_codeSpan, (m) => hold(m.group(2)!.trim()))
      .replaceAllMapped(_escape, (m) => hold(m.group(1)!))
      .replaceAllMapped(_image, (m) => m.group(1)!)
      .replaceAllMapped(_link, (m) => linked(m.group(1)!, m.group(2)!))
      .replaceAllMapped(_refLink, (m) {
        final label = m.group(2)!.trim().isEmpty ? m.group(1)! : m.group(2)!;
        final url = refs[label.trim().toLowerCase()];
        return url == null ? m.group(1)! : linked(m.group(1)!, url);
      })
      .replaceAll(_footnoteRef, '')
      .replaceAllMapped(_autolink,
          (m) => hold(m.group(1)!.replaceFirst('mailto:', '')))
      .replaceAll(_lineBreakTag, ' ')
      .replaceAll(_tag, '')
      .replaceAllMapped(_strong, (m) => m.group(1)!)
      .replaceAllMapped(_strongUnder, (m) => m.group(1)!)
      .replaceAllMapped(_em, (m) => m.group(1)!)
      .replaceAllMapped(_emUnder, (m) => m.group(1)!)
      .replaceAllMapped(_strike, (m) => m.group(1)!);
  // Twice: something held may sit inside something held (a link's words).
  for (var pass = 0; pass < 2; pass++) {
    t = t.replaceAllMapped(_held, (m) => kept[int.parse(m.group(1)!)]);
  }
  return t.replaceAll(_spaces, ' ').trim();
}
