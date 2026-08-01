/// EPUB → spine rows: intake_core's chapter/block shapes flattened onto the
/// one content spine (ADR-0002), ready for `SpineDao.insertSegments`.
///
/// Mapping: each chapter title becomes a heading segment (empty titles emit
/// none), prose stays prose, code/table keep their kinds, math rides as code
/// (the spine has no math kind yet — the tokenizer's `[code]` sentinel is the
/// honest stand-in), figures carry their alt text (or src when alt-less);
/// image bytes are out of the alpha's scope.
library;

import 'package:intake_core/intake_core.dart';

typedef SegmentRow = ({int idx, String kind, String text});

List<SegmentRow> flattenEpub(EpubDoc doc) {
  final rows = <SegmentRow>[];
  void add(String kind, String text) =>
      rows.add((idx: rows.length, kind: kind, text: text));

  for (final chapter in doc.chapters) {
    if (chapter.title.isNotEmpty) add('heading', chapter.title);
    for (final block in chapter.blocks) {
      switch (block) {
        case TextBlock(:final text):
          add('prose', text);
        case SegmentBlock(:final kind, :final content):
          add(
              switch (kind) {
                IntakeSegmentKind.code => 'code',
                IntakeSegmentKind.table => 'table',
                IntakeSegmentKind.math => 'code',
              },
              content);
        case FigureBlock(:final src, :final alt):
          add('figure', alt.isNotEmpty ? alt : src);
      }
    }
  }
  return rows;
}
