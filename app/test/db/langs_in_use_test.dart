import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';

/// Settings › Read aloud voices lists "every language the reader meets"
/// (board-0131). A Russian translation of an English episode is met in
/// the reader, but no work or show is in Russian, so Russian was missing
/// from the list and no Russian voice could be picked there (owner,
/// 12 Nov: "I can't get a read-aloud Russian voice").
void main() {
  late AppDatabase db;
  late int profileId;
  late int workId;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'article',
        title: 'A Story',
        persistence: 'work',
        firstSeenEpochDay: 100,
        lang: 'en');
  });
  tearDown(() => db.close());

  test('a translation’s language is a language in use', () async {
    await db.spineDao.upsertTranslationSentence(
        workId: workId,
        segmentIdx: 0,
        sentenceIdx: 0,
        lang: 'ru',
        sourceText: 'Hello.',
        body: 'Привет.');
    expect(await db.spineDao.langsInUse(profileId), {'en', 'ru'});
  });

  test('a whole-transcript translation layer’s language is too', () async {
    await db.spineDao.insertSegments(
        workId, const [(idx: 0, kind: 'prose', text: 'Hello.')]);
    await db.spineDao.insertLayers(workId,
        const [(segmentIdx: 0, lang: 'de', kind: 'mt', text: 'Hallo.')]);
    expect(await db.spineDao.langsInUse(profileId), {'en', 'de'});
  });

  test('another reader’s translations are not this one’s', () async {
    final other = await db.profilesDao.create('Bo');
    await db.spineDao.upsertTranslationSentence(
        workId: workId,
        segmentIdx: 0,
        sentenceIdx: 0,
        lang: 'ru',
        sourceText: 'Hello.',
        body: 'Привет.');
    expect(await db.spineDao.langsInUse(other), isEmpty);
  });
}
