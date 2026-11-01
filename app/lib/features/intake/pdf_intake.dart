/// PDF intake (1.6.0, owner: "also read other formats like PDF please"):
/// a PDF with a text layer becomes a book in the Library, as an EPUB
/// does, so the reader, read aloud, translation, study and search work
/// on it unchanged.
///
/// PDFium reads the characters ([PdfReader]); intake_core's
/// `pdfToBlocks` rebuilds headings, paragraphs and reading order. What
/// that could not be sure of is said on the work's page rather than
/// hidden: pages that are pictures, and pages whose order is the file's
/// own.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:intake_core/intake_core.dart';

import '../../db/database.dart';
import 'epub_flatten.dart' show SegmentRow;
import 'paste_intake.dart' show epochDayUtcNow;
import 'pdf_reader.dart';

/// What Trellis says of a PDF that is only pictures of pages.
const pdfNoTextMessage =
    'This PDF is pictures of pages, with no text Trellis can read.';

typedef _ParsedPdf = ({
  String title,
  List<SegmentRow> segments,
  int pageCount,
  List<int> untrusted,
  List<int> textless,
});

/// PDFium is not safe to enter from two threads at once, and each import
/// reads on its own isolate: one at a time.
Future<void> _reading = Future.value();

/// Stores the PDF at [path] as one spine work and returns its id.
///
/// Throws [PdfUnreadableException], whose message is fit to show as it
/// is, for a file that is not a PDF, is locked, is too long, or is
/// pictures of pages ([pdfNoTextMessage]). [read] stands in for PDFium
/// in tests and then runs here, not on another isolate.
Future<int> importPdfFile(
    {required AppDatabase db,
    required int profileId,
    required String path,
    String? sourceName,
    PdfReader? read}) async {
  final _ParsedPdf parsed;
  if (read != null) {
    parsed = _build(read(path), sourceName);
  } else {
    final before = _reading;
    final mine = before.then((_) =>
        compute(_readAndBuild, (path: path, name: sourceName)));
    _reading = mine.then<void>((_) {}, onError: (_) {});
    parsed = await mine;
  }
  if (parsed.segments.isEmpty) {
    throw const PdfUnreadableException(pdfNoTextMessage);
  }
  return db.transaction(() async {
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'book',
        title: parsed.title,
        persistence: 'work',
        firstSeenEpochDay: epochDayUtcNow());
    await db.spineDao.insertSegments(workId, parsed.segments);
    final about = _aboutOf(parsed);
    if (about != null) {
      await db.feedsDao.fillNotes(workId,
          html: [for (final s in about) '<p>${_escape.convert(s)}</p>'].join(),
          plain: about.join(' '));
    }
    return workId;
  });
}

const _escape = HtmlEscape(HtmlEscapeMode.element);

// Reading a long PDF and working out its order is seconds of work;
// [compute] keeps both off the UI isolate. Top-level, so the message
// holds only data.
_ParsedPdf _readAndBuild(({String path, String? name}) m) =>
    _build(readPdfWithPdfium(m.path), m.name);

_ParsedPdf _build(PdfRead read, String? sourceName) {
  final doc = pdfToBlocks(read.pages,
      metaTitle: read.metaTitle, sourceName: sourceName);
  return (
    title: doc.title,
    segments: [
      for (final (i, b) in doc.blocks.indexed)
        (idx: i, kind: b.heading ? 'heading' : 'prose', text: b.text),
    ],
    pageCount: doc.pageCount,
    untrusted: doc.untrustedPages,
    textless: doc.textlessPages,
  );
}

/// The sentences for the work's About, or null when the file gave no
/// cause for any.
List<String>? _aboutOf(_ParsedPdf p) {
  if (p.untrusted.isEmpty && p.textless.isEmpty) return null;
  String cap(String s) => s[0].toUpperCase() + s.substring(1);
  return [
    'From a PDF of ${p.pageCount} pages.',
    if (p.textless.isNotEmpty)
      p.textless.length == 1
          ? '${cap(pagesPhrase(p.textless))} is a picture, with no text '
              'Trellis can read.'
          : '${cap(pagesPhrase(p.textless))} are pictures, with no text '
              'Trellis can read.',
    if (p.untrusted.isNotEmpty)
      'The layout of ${pagesPhrase(p.untrusted)} couldn’t be worked out, '
          'so ${p.untrusted.length == 1 ? 'it is' : 'they are'} in the '
          'order the file gives.',
  ];
}

/// "page 3", "pages 3 and 7", "pages 3–5, 9 and 11–12".
String pagesPhrase(List<int> pages) {
  final runs = <String>[];
  for (var i = 0; i < pages.length; i++) {
    final start = pages[i];
    while (i + 1 < pages.length && pages[i + 1] == pages[i] + 1) {
      i++;
    }
    runs.add(pages[i] == start ? '$start' : '$start–${pages[i]}');
  }
  final list = runs.length == 1
      ? runs.single
      : '${runs.sublist(0, runs.length - 1).join(', ')} and ${runs.last}';
  return '${pages.length == 1 ? 'page' : 'pages'} $list';
}
