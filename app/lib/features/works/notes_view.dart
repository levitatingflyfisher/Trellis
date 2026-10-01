/// Show notes as text (1.5.4). The HTML was sanitized before it was
/// stored (intake_core's `sanitizeNotesHtml`), so only links, lists,
/// paragraphs, bold, italic and breaks reach here. Nothing is fetched:
/// an image was already turned into its alt text. A link asks before it
/// leaves the app, and a time like `12:34` in an episode's notes plays
/// from there.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

typedef NoteTimestamp = ({int start, int end, Duration at});

final _timestampRe = RegExp(
  r'(?<![\d:])(?:(\d{1,2}):)?(\d{1,2}):([0-5]\d)(?![\d:])',
);

/// Every `h:mm:ss` or `mm:ss` in [text]. In the h:mm:ss form the minutes
/// must be under 60; a run of digits and colons longer than that (a
/// phone number, a ratio) is not a time.
List<NoteTimestamp> parseNoteTimestamps(String text) {
  final out = <NoteTimestamp>[];
  for (final m in _timestampRe.allMatches(text)) {
    final h = m.group(1) == null ? 0 : int.parse(m.group(1)!);
    final min = int.parse(m.group(2)!);
    final s = int.parse(m.group(3)!);
    if (m.group(1) != null && min > 59) continue;
    out.add((
      start: m.start,
      end: m.end,
      at: Duration(hours: h, minutes: min, seconds: s),
    ));
  }
  return out;
}

class _Run {
  final String text;
  final bool bold;
  final bool italic;
  final String? href;
  const _Run(this.text, {this.bold = false, this.italic = false, this.href});
}

class _Block {
  final String prefix;
  final int indent;
  final List<_Run> runs = [];
  _Block({this.prefix = '', this.indent = 0});
  int get length => runs.fold(0, (n, r) => n + r.text.length);
}

/// The notes as paragraphs of styled runs. Block elements start a new
/// paragraph; inline ones style the runs inside it.
List<_Block> _blocksOf(String html) {
  final blocks = <_Block>[];
  _Block? current;
  _Block open({String prefix = '', int indent = 0}) =>
      current = _Block(prefix: prefix, indent: indent)..also(blocks.add);

  void walk(
    dom.Node n, {
    bool bold = false,
    bool italic = false,
    String? href,
    int indent = 0,
    String bullet = '',
  }) {
    if (n is dom.Text) {
      final text = n.text.replaceAll(RegExp(r'\s+'), ' ');
      if (text.trim().isEmpty && (current == null || current!.runs.isEmpty)) {
        return;
      }
      (current ?? open(indent: indent)).runs.add(
        _Run(text, bold: bold, italic: italic, href: href),
      );
      return;
    }
    if (n is! dom.Element) return;
    final tag = n.localName ?? '';
    void children({bool b = false, bool i = false, String? h, int ind = 0}) {
      for (final c in n.nodes) {
        walk(
          c,
          bold: bold || b,
          italic: italic || i,
          href: h ?? href,
          indent: indent + ind,
        );
      }
    }

    switch (tag) {
      case 'p':
        open(indent: indent);
        children();
        current = null;
      case 'blockquote':
        current = null;
        children(i: true, ind: 1);
        current = null;
      case 'ul' || 'ol':
        current = null;
        var k = 0;
        for (final c in n.nodes) {
          if (c is dom.Element && c.localName == 'li') {
            k++;
            open(prefix: tag == 'ol' ? '$k. ' : '• ', indent: indent + 1);
            for (final cc in c.nodes) {
              walk(
                cc,
                bold: bold,
                italic: italic,
                href: href,
                indent: indent + 1,
              );
            }
            current = null;
          }
        }
      case 'li':
        open(prefix: '• ', indent: indent + 1);
        children();
        current = null;
      case 'br':
        current = null;
      case 'strong' || 'b':
        children(b: true);
      case 'em' || 'i':
        children(i: true);
      case 'a':
        children(h: n.attributes['href']);
      default:
        children();
    }
  }

  for (final n in html_parser.parseFragment(html).nodes) {
    walk(n);
  }
  for (final b in blocks) {
    if (b.runs.isNotEmpty) {
      final first = b.runs.first;
      b.runs[0] = _Run(
        first.text.trimLeft(),
        bold: first.bold,
        italic: first.italic,
        href: first.href,
      );
      final last = b.runs.last;
      b.runs[b.runs.length - 1] = _Run(
        last.text.trimRight(),
        bold: last.bold,
        italic: last.italic,
        href: last.href,
      );
    }
  }
  return [
    for (final b in blocks)
      if (b.length > 0) b,
  ];
}

extension<T> on T {
  void also(void Function(T) f) => f(this);
}

/// Characters shown before "Show more" on a foldable view: a phone
/// screen or so of notes, enough to tell what the episode is about.
const notesFoldChars = 700;

class NotesView extends StatefulWidget {
  final String html;

  /// Starts long notes folded behind "Show more".
  final bool foldable;

  /// Null leaves times as plain text (a text work's description).
  final void Function(Duration at)? onTimestamp;

  /// Times past this (the episode's end) stay plain text: "doors at
  /// 10:30" in a 40-minute episode is a clock time, not a place.
  final Duration? maxTimestamp;

  /// Opens a link once the reader has said yes. Null shows links as
  /// plain text.
  final Future<void> Function(Uri uri)? onOpenLink;

  const NotesView({
    super.key,
    required this.html,
    this.foldable = false,
    this.onTimestamp,
    this.maxTimestamp,
    this.onOpenLink,
  });

  @override
  State<NotesView> createState() => _NotesViewState();
}

class _NotesViewState extends State<NotesView> {
  late List<_Block> _blocks = _blocksOf(widget.html);
  bool _expanded = false;
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void didUpdateWidget(NotesView old) {
    super.didUpdateWidget(old);
    if (old.html != widget.html) _blocks = _blocksOf(widget.html);
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  TapGestureRecognizer _tap(VoidCallback onTap) {
    final r = TapGestureRecognizer()..onTap = onTap;
    _recognizers.add(r);
    return r;
  }

  Future<void> _confirmLink(String href) async {
    final uri = Uri.tryParse(href);
    final open = widget.onOpenLink;
    if (uri == null || open == null) return;
    // Checked again here, not only at storage: whatever HTML a later
    // caller hands this view, only the web and email leave the app.
    final scheme = uri.scheme.toLowerCase();
    final web = (scheme == 'http' || scheme == 'https') && uri.host.isNotEmpty;
    if (!web && scheme != 'mailto') return;
    final host = uri.scheme == 'mailto' ? uri.path : uri.host;
    final yes = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          child: Padding(
            key: const Key('link-confirm'),
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  uri.scheme == 'mailto'
                      ? 'Write an email?'
                      : 'Open this link?',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Text(host, style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  href,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Text(
                  uri.scheme == 'mailto'
                      ? 'It opens in your email app.'
                      : 'It opens in your browser, which will contact this '
                            'site.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      key: const Key('link-cancel'),
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const Key('link-open'),
                      onPressed: () => Navigator.of(context).pop(true),
                      child: Text(
                        uri.scheme == 'mailto' ? 'Open email' : 'Open',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    if (yes == true) await open(uri);
  }

  List<InlineSpan> _spans(_Block block, ThemeData theme, int? budget) {
    final spans = <InlineSpan>[];
    final linkStyle = TextStyle(
      color: theme.colorScheme.primary,
      decoration: TextDecoration.underline,
    );
    var left = budget;
    for (final run in block.runs) {
      if (left != null && left <= 0) break;
      var text = run.text;
      if (left != null && text.length > left) {
        text = '${text.substring(0, left).trimRight()}…';
      }
      if (left != null) left -= run.text.length;
      final base = TextStyle(
        fontWeight: run.bold ? FontWeight.w700 : null,
        fontStyle: run.italic ? FontStyle.italic : null,
      );
      final href = run.href;
      if (href != null && widget.onOpenLink != null) {
        spans.add(
          TextSpan(
            text: text,
            style: base.merge(linkStyle),
            recognizer: _tap(() => _confirmLink(href)),
          ),
        );
        continue;
      }
      final onTime = widget.onTimestamp;
      final times = onTime == null
          ? const <NoteTimestamp>[]
          : [
              for (final t in parseNoteTimestamps(text))
                if (widget.maxTimestamp == null || t.at <= widget.maxTimestamp!)
                  t,
            ];
      var at = 0;
      for (final t in times) {
        if (t.start > at) {
          spans.add(TextSpan(text: text.substring(at, t.start), style: base));
        }
        spans.add(
          TextSpan(
            text: text.substring(t.start, t.end),
            style: base.merge(linkStyle),
            recognizer: _tap(() => onTime!(t.at)),
          ),
        );
        at = t.end;
      }
      if (at < text.length) {
        spans.add(TextSpan(text: text.substring(at), style: base));
      }
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final theme = Theme.of(context);
    final total = _blocks.fold(0, (n, b) => n + b.length);
    final folds = widget.foldable && total > notesFoldChars * 1.3;
    final folded = folds && !_expanded;
    final children = <Widget>[];
    var used = 0;
    for (final block in _blocks) {
      int? budget;
      if (folded) {
        if (used >= notesFoldChars) break;
        budget = notesFoldChars - used;
      }
      used += block.length;
      children.add(
        Padding(
          padding: EdgeInsets.only(left: 16.0 * block.indent, bottom: 10),
          child: Text.rich(
            TextSpan(
              style: theme.textTheme.bodyLarge,
              children: [
                if (block.prefix.isNotEmpty) TextSpan(text: block.prefix),
                ..._spans(block, theme, budget),
              ],
            ),
          ),
        ),
      );
    }
    if (folds) {
      children.add(
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: Key(_expanded ? 'notes-less' : 'notes-more'),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => setState(() => _expanded = !_expanded),
            child: Text(_expanded ? 'Show less' : 'Show more'),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}
