/// Word documents (.docx) as works (owner, 17 Nov 2026: "Trellis opens
/// .docx files directly"). intake_core reads the file; this stores it.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:intake_core/intake_core.dart';

import '../../db/database.dart';
import 'epub_flatten.dart' show SegmentRow;
import 'paste_intake.dart' show epochDayUtcNow;

/// What Android and the web call a .docx.
const docxMimeType =
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document';

/// Whether [name] (or its MIME type) says the file is a .docx.
bool isDocxName(String name, {String? mimeType}) =>
    (mimeType ?? '').toLowerCase() == docxMimeType ||
    name.toLowerCase().endsWith('.docx');

typedef DocxRows = ({String title, List<SegmentRow> rows, List<LinkRow> links});

/// A Word document's blocks as spine rows, with its web links by row.
/// Rows are numbered from [firstIdx], so a book of several documents can
/// put one after another.
DocxRows docxRows(DocxDoc doc, {int firstIdx = 0}) {
  final rows = <SegmentRow>[];
  final links = <LinkRow>[];
  void add(String kind, String text) =>
      rows.add((idx: firstIdx + rows.length, kind: kind, text: text));
  for (final b in doc.blocks) {
    switch (b) {
      case HeadingBlock(:final text):
        add('heading', text);
      case TextBlock(:final text, links: final found):
        for (final l in found) {
          links.add((
            segIdx: firstIdx + rows.length,
            start: l.start,
            end: l.end,
            href: l.href
          ));
        }
        add('prose', text);
      case SegmentBlock(:final kind, :final content):
        add(kind == IntakeSegmentKind.table ? 'table' : 'code', content);
      case FigureBlock(:final alt):
        if (alt.isNotEmpty) add('figure', alt);
    }
  }
  return (title: doc.title, rows: rows, links: links);
}

/// Stores [rows] as one book in the Library and returns its id: a Word
/// document, or a web book brought in from its contents page.
/// Throws [FormatException] when there is nothing in it to read.
Future<int> storeBookRows(AppDatabase db,
    {required int profileId, required DocxRows rows, String? sourceUrl}) {
  if (rows.rows.isEmpty) {
    throw const FormatException('There was nothing in that document to read.');
  }
  return db.transaction(() async {
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'book',
        title: rows.title,
        persistence: 'work',
        firstSeenEpochDay: epochDayUtcNow(),
        sourceUrl: sourceUrl);
    await db.spineDao.insertSegments(workId, rows.rows);
    await db.spineDao.insertLinks(workId, rows.links);
    return workId;
  });
}

/// Reads the .docx [bytes] and stores it as a book; see [storeBookRows].
/// Throws [FormatException] (or [DocxTooLargeException]) with words fit
/// to show when it cannot be read.
Future<int> importDocxBytes(
        {required AppDatabase db,
        required int profileId,
        required List<int> bytes,
        String? sourceName,
        String? sourceUrl}) async =>
    storeBookRows(db,
        profileId: profileId,
        rows: await compute(_parseBytes, (bytes: bytes, name: sourceName)),
        sourceUrl: sourceUrl);

/// [importDocxBytes] from a file on disk: only the path crosses to the
/// parsing isolate.
Future<int> importDocxFile(
        {required AppDatabase db,
        required int profileId,
        required String path,
        String? sourceName}) async =>
    storeBookRows(db,
        profileId: profileId,
        rows: await compute(_parseFile, (path: path, name: sourceName)));

DocxRows _parseBytes(({List<int> bytes, String? name}) m) =>
    docxRows(parseDocx(m.bytes, sourceName: m.name));

DocxRows _parseFile(({String path, String? name}) m) =>
    _parseBytes((bytes: File(m.path).readAsBytesSync(), name: m.name));
