/// Switching an episode's language while it plays (1.6.18, owner: "it
/// should live together"): the episode and its versions are one thing in
/// several languages, and a switch keeps the place by paragraph.
///
/// A version's paragraph i is the i-th of its episode's paragraphs that
/// have a translation in its language (how the version was made, in
/// `storeSpokenEpisode`), so the translation rows give the map back.
library;

import 'package:drift/drift.dart';

import '../../db/database.dart';

/// One language of an episode: the work that plays it.
typedef EpisodeLanguage = ({String lang, Work work});

/// The episode [work] belongs to, first, then each of its versions: the
/// episode's own language (or 'und' when nobody knows it) and each
/// version's. Empty when [work] is a version whose episode is gone.
Future<List<EpisodeLanguage>> episodeLanguages(
    AppDatabase db, Work work) async {
  var original = work;
  if (work.kind == 'version') {
    final v = await db.versionsDao.versionOf(work.id);
    final o = v == null ? null : await db.spineDao.workById(v.originalId);
    if (o == null) return const [];
    original = o;
  }
  final out = <EpisodeLanguage>[(lang: original.lang ?? 'und', work: original)];
  final versions = await db.versionsDao.versionsOf(original.id)
    ..sort((a, b) => a.lang.compareTo(b.lang));
  for (final v in versions) {
    final w = await db.spineDao.workById(v.workId);
    if (w != null) out.add((lang: v.lang, work: w));
  }
  return out;
}

/// Where in [to] the paragraph [from] is in at [at] (ms) starts, in ms;
/// null when the paragraphs cannot be matched (the caller keeps the same
/// share of the way in).
Future<int?> placeIn(AppDatabase db,
    {required Work from, required int at, required Work to}) async {
  // Both sides as the episode's paragraph numbers.
  final fromMap = await _paragraphs(db, from);
  final toMap = await _paragraphs(db, to);
  if (fromMap == null || toMap == null) return null;
  final fromAligned = await db.spineDao.alignmentsOf(from.id);
  if (fromAligned.isEmpty) return null;
  var here = fromAligned.first.segmentIdx;
  for (final a in fromAligned) {
    if (a.tStartMs <= at) here = a.segmentIdx;
  }
  if (here >= fromMap.length) return null;
  final episodeParagraph = fromMap[here];
  // The last of [to]'s paragraphs at or before it.
  int? target;
  for (var i = 0; i < toMap.length; i++) {
    if (toMap[i] <= episodeParagraph) target = i;
  }
  if (target == null) return null;
  final toAligned = await db.spineDao.alignmentsOf(to.id);
  for (final a in toAligned) {
    if (a.segmentIdx == target) return a.tStartMs;
  }
  return null;
}

/// [work]'s paragraph i as the episode's paragraph number: itself for the
/// episode; for a version, its language's translated paragraphs in order.
/// Null when that list does not match the version's paragraphs.
Future<List<int>?> _paragraphs(AppDatabase db, Work work) async {
  final own = (await db.spineDao.segmentsOf(work.id)).length;
  if (work.kind != 'version') return [for (var i = 0; i < own; i++) i];
  final v = await db.versionsDao.versionOf(work.id);
  if (v == null) return null;
  final rows = await (db.selectOnly(db.translationSentences, distinct: true)
        ..addColumns([db.translationSentences.segmentIdx])
        ..where(db.translationSentences.workId.equals(v.originalId) &
            db.translationSentences.lang.equals(v.lang))
        ..orderBy([OrderingTerm.asc(db.translationSentences.segmentIdx)]))
      .map((r) => r.read(db.translationSentences.segmentIdx)!)
      .get();
  return rows.length == own ? rows : null;
}
