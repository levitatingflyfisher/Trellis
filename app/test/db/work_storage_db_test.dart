import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';

/// 1.5.8: a transcript or one translation can be deleted on its own, and
/// the storage page can say how much of each a work holds.
void main() {
  late AppDatabase db;
  late int profile;
  late int workId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profile = await db.profilesDao.create('Ada');
    final feed = await db.feedsDao
        .insertFeed(profileId: profile, url: 'https://c.test/f', title: 'C');
    workId = await db.spineDao.insertWork(
        profileId: profile,
        kind: 'episode',
        title: 'Lighthouse',
        persistence: 'work',
        firstSeenEpochDay: 1);
    await db.feedsDao.insertEpisode(
        workId: workId,
        feedId: feed,
        guid: 'g',
        enclosureUrl: 'https://c.test/1.mp3',
        publishedAtMs: 1);
    await db.spineDao.insertSegments(workId, const [
      (idx: 0, kind: 'prose', text: 'The lighthouse keeper.'),
      (idx: 1, kind: 'prose', text: 'He climbs the stairs.'),
    ]);
    await db.spineDao.insertAlignments(workId, const [
      (segmentIdx: 0, tStartMs: 0, tEndMs: 1000),
      (segmentIdx: 1, tStartMs: 1000, tEndMs: 2000),
    ]);
    await db.spineDao.insertLayers(workId, const [
      (segmentIdx: 0, lang: 'en', kind: 'mt', text: 'The keeper.'),
    ]);
    for (final lang in ['de', 'ru']) {
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: lang,
          sourceText: 'The lighthouse keeper.',
          body: 'Der Leuchtturmwärter.');
    }
    await db.spineDao.savePosition(
        profileId: profile,
        workId: workId,
        segmentIdx: 1,
        wordIdx: 0,
        lastModality: 'read');
    await db.feedsDao.savePlayerPosition(
        profileId: profile, workId: workId, tMs: 1500);
    await db.spineDao.setActiveTranslationLang(workId, 'ru');
    await db.spineDao.setReadLang(workId, 'ru');
    await db.spineDao.setTranslationOnly(workId, true);
    await db.spineDao.setTranslationRunLang(workId, 'ru');
    await db.into(db.captures).insert(CapturesCompanion.insert(
        profileId: profile,
        workId: workId,
        positionMs: 500,
        createdAtMs: 1,
        segmentIdx: const Value(0)));
  });
  tearDown(() => db.close());

  Future<int> count(String table) async => (await db
          .customSelect('SELECT count(*) AS n FROM $table')
          .getSingle())
      .read<int>('n');

  test('deleting the transcript takes its sentences, layers, translations '
      'and reading place, and keeps the listening place', () async {
    expect(await count('segments_fts'), 2);
    await db.spineDao.deleteTranscript(workId);
    expect(await db.spineDao.segmentsOf(workId), isEmpty);
    expect(await db.spineDao.alignmentsOf(workId), isEmpty);
    expect(await db.spineDao.layerLangsOf(workId, kind: 'mt'), isEmpty);
    expect(await db.spineDao.translationLangsOf(workId), isEmpty);
    expect(
        await db.spineDao.position(profileId: profile, workId: workId), isNull);
    expect(
        await db.feedsDao.playerPosition(profileId: profile, workId: workId),
        isNotNull);
    // Search stops finding the words.
    expect(await count('segments_fts'), 0);
    final work = (await db.spineDao.workById(workId))!;
    expect(work.activeTranslationLang, isNull);
    expect(work.readLang, isNull);
    expect(work.translationView, isNull);
    expect(work.translationRunLang, isNull);
    final listening = await db.feedsDao.listeningOf(profile);
    expect(listening.transcribed, isNot(contains(workId)));
    // A capture stays, keeps its time, and waits for the next transcript.
    final capture = (await db.capturesDao.capturesOf(workId)).single;
    expect(capture.positionMs, 500);
    expect(capture.segmentIdx, isNull);
  });

  test('deleting one translation leaves the transcript and the other '
      'languages', () async {
    await db.spineDao.deleteTranslation(workId, 'ru');
    expect(await db.spineDao.translationLangsOf(workId), ['de']);
    expect(await db.spineDao.segmentsOf(workId), hasLength(2));
    final work = (await db.spineDao.workById(workId))!;
    expect(work.activeTranslationLang, isNull);
    expect(work.showTranslationLayer, isFalse);
    expect(work.readLang, isNull);
    expect(work.translationView, isNull);
    expect(work.translationRunLang, isNull);
  });

  test('deleting a translation takes a whole-segment layer in that '
      'language, never the transcript', () async {
    await db.spineDao.deleteTranslation(workId, 'en');
    expect(await db.spineDao.layerLangsOf(workId, kind: 'mt'), isEmpty);
    expect(await db.spineDao.segmentsOf(workId), hasLength(2));
    // Another language's choices stand.
    expect((await db.spineDao.workById(workId))!.readLang, 'ru');
  });

  test('stored text: one row for the transcript and one per translation '
      'language, in bytes', () async {
    final rows = await db.spineDao.storedText();
    final byLang = {for (final r in rows) r.lang: r};
    expect(byLang.keys.toSet(), {null, 'de', 'ru', 'en'});
    expect(rows.every((r) => r.workId == workId), isTrue);
    // Bytes, not characters: "ä" is two.
    expect(byLang['de']!.bytes, greaterThan('Der Leuchtturmwärter.'.length));
    expect(byLang[null]!.bytes, greaterThan(0));
  });

  test('stored text narrows to one work', () async {
    final other = await db.spineDao.insertWork(
        profileId: profile,
        kind: 'article',
        title: 'Other',
        persistence: 'work',
        firstSeenEpochDay: 1);
    await db.spineDao.insertSegments(
        other, const [(idx: 0, kind: 'prose', text: 'Hello.')]);
    await db.spineDao.upsertTranslationSentence(
        workId: other,
        segmentIdx: 0,
        sentenceIdx: 0,
        lang: 'fr',
        sourceText: 'Hello.',
        body: 'Bonjour.');
    final rows = await db.spineDao.storedText(workId: other);
    expect(rows.map((r) => (r.workId, r.lang)), [(other, 'fr')]);
    expect(await db.spineDao.storedText(workId: workId), hasLength(4));
  });

  test('a text work has no transcript row, only its translations',
      () async {
    final book = await db.spineDao.insertWork(
        profileId: profile,
        kind: 'article',
        title: 'Book',
        persistence: 'work',
        firstSeenEpochDay: 1);
    await db.spineDao.insertSegments(
        book, const [(idx: 0, kind: 'prose', text: 'Call me Ishmael.')]);
    final rows = await db.spineDao.storedText();
    expect(rows.where((r) => r.workId == book), isEmpty);
  });
}
