/// Where a card made or edited by hand is written: into its course's own
/// text, read fresh from the database at the moment of writing so an
/// edit never overwrites another made since the screen was opened.
library;

import 'package:study_core/study_core.dart' as study;

import '../../db/database.dart';
import 'card_editing.dart';

int _now() => DateTime.now().millisecondsSinceEpoch;

Future<String> _rawOf(AppDatabase db, int courseRowId) async {
  final row = await db.studyDao.courseRowById(courseRowId);
  if (row == null) throw StateError('the course is gone');
  return row.raw;
}

Set<String> _itemIds(String raw) => {
      for (final n in study.parseCourseString(raw).nodes)
        for (final i in n.items) i.id,
    };

/// Adds a card made from [draft] to step [nodeId]; returns its id.
Future<String> addCard(AppDatabase db, int courseRowId,
    {required String nodeId,
    required CardDraft draft,
    int Function() now = _now}) async {
  final raw = await _rawOf(db, courseRowId);
  final id = newCardId(_itemIds(raw), now());
  await db.studyDao.saveCourseRaw(courseRowId,
      courseWithNewCard(raw, nodeId: nodeId, itemId: id, draft: draft));
  return id;
}

Future<void> editCard(
    AppDatabase db, int courseRowId, String itemId, CardDraft draft) async {
  final raw = await _rawOf(db, courseRowId);
  await db.studyDao
      .saveCourseRaw(courseRowId, courseWithEditedCard(raw, itemId, draft));
}

Future<void> deleteCard(AppDatabase db, int courseRowId, String itemId) async {
  final raw = await _rawOf(db, courseRowId);
  await db.studyDao.saveCourseRaw(courseRowId, courseWithoutCard(raw, itemId));
}

/// Adds [draft] to the reader's My cards course, making the course with
/// its first card. Returns the course row id.
Future<int> addToMyCards(AppDatabase db, int profileId, CardDraft draft,
    {int Function() now = _now}) async {
  final row = await db.studyDao.courseRowOf(profileId, myCardsCourseId);
  if (row == null) {
    return db.studyDao.importCourse(
        profileId: profileId,
        raw: newMyCardsCourse(itemId: newCardId(const {}, now()), draft: draft),
        nowMs: now());
  }
  final node = study.parseCourseString(row.raw).nodes.last.id;
  await addCard(db, row.id, nodeId: node, draft: draft, now: now);
  return row.id;
}
