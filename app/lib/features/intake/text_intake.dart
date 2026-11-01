/// Markdown and plain text files as works (owner, 1.6.x: "tried to open a
/// markdown file in Trellis and could not").
///
/// A `.md` or `.markdown` file is read as Markdown (intake_core's
/// `parseMarkdown`): headings are headings, links keep their addresses,
/// lists and tables read well, and no markup is left. A `.txt` file is
/// read with the plain-text rules a paste uses, so a `#` in it stays
/// what the writer typed.
library;

import 'dart:convert';
import 'dart:io';

import 'package:intake_core/intake_core.dart';
import 'package:loom_core/loom_core.dart' as core;

import '../../db/database.dart';
import 'epub_flatten.dart' show SegmentRow;
import 'paste_intake.dart' show epochDayUtcNow;

/// What a text file may be, read whole into memory.
const maxTextFileBytes = 8 * 1024 * 1024;

/// A text file too large to read here; [message] is fit to show.
class TextTooLargeException extends FormatException {
  const TextTooLargeException()
      : super('That file is too large to read here.');
}

String _endingOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

String _bare(String name) {
  final dot = name.lastIndexOf('.');
  final bare = (dot > 0 ? name.substring(0, dot) : name).trim();
  return bare.isEmpty ? 'Untitled' : bare;
}

/// Whether [name] (or its MIME type) says the file is Markdown.
bool isMarkdownName(String name, {String? mimeType}) {
  final mime = (mimeType ?? '').toLowerCase();
  return mime == 'text/markdown' ||
      mime == 'text/x-markdown' ||
      const ['md', 'markdown'].contains(_endingOf(name));
}

/// Whether [name] is a text file "Import a file" reads.
bool isTextFileName(String name) =>
    const ['md', 'markdown', 'txt'].contains(_endingOf(name));

/// A Markdown document as spine rows: its blocks in order, markup gone.
List<SegmentRow> markdownRows(MarkdownDoc doc) => [
      for (final (i, b) in doc.blocks.indexed)
        (
          idx: i,
          kind: switch (b.kind) {
            MarkdownKind.heading => 'heading',
            MarkdownKind.prose => 'prose',
            MarkdownKind.code => 'code',
          },
          text: b.text
        ),
    ];

/// [text] as a title and rows: Markdown when [markdown], else the
/// plain-text rules. [name] names the work when the text does not.
({String title, List<SegmentRow> rows}) textFileRows(String text,
    {required String name, required bool markdown}) {
  if (markdown) {
    final doc = parseMarkdown(text, sourceName: name);
    return (title: doc.title, rows: markdownRows(doc));
  }
  final parsed = core.parseTextFile(text, _bare(name));
  return (
    title: parsed.title,
    rows: [
      for (final s in parsed.segments)
        (idx: s.idx, kind: s.kind.name, text: s.text)
    ],
  );
}

/// Stores the text file at [path] as one work in the Library and returns
/// its id. Throws [TextTooLargeException] over [maxTextFileBytes], and
/// [FormatException] for a file with nothing to read in it.
Future<int> importTextFile(
    {required AppDatabase db,
    required int profileId,
    required String path,
    required String name}) async {
  final file = File(path);
  if (await file.length() > maxTextFileBytes) {
    throw const TextTooLargeException();
  }
  return importTextBytes(
      db: db, profileId: profileId, bytes: await file.readAsBytes(), name: name);
}

/// [importTextFile] from bytes already in hand (the web tier, where a
/// picked file has no path).
Future<int> importTextBytes(
    {required AppDatabase db,
    required int profileId,
    required List<int> bytes,
    required String name}) async {
  if (bytes.length > maxTextFileBytes) throw const TextTooLargeException();
  final parsed = textFileRows(utf8.decode(bytes, allowMalformed: true),
      name: name, markdown: isMarkdownName(name));
  if (parsed.rows.isEmpty) {
    throw const FormatException('There was nothing in that file to read.');
  }
  return db.transaction(() async {
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'note',
        title: parsed.title,
        persistence: 'work',
        firstSeenEpochDay: epochDayUtcNow());
    await db.spineDao.insertSegments(workId, parsed.rows);
    return workId;
  });
}
