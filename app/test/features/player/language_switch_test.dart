import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/language_switch.dart';

/// Switching an episode's language keeps the place by sentence (1.6.18):
/// the same paragraph, in the other language's audio.
void main() {
  late AppDatabase db;
  late Work original;
  late Work es;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final p = await db.profilesDao.create('Ada');
    final feed = await db.feedsDao
        .insertFeed(profileId: p, url: 'https://cast.test/f', title: 'Show');
    final o = await db.spineDao.insertWork(
        profileId: p,
        kind: 'episode',
        title: 'Harbour',
        persistence: 'ephemeron',
        firstSeenEpochDay: 1,
        sourceUrl: 'https://cast.test/1.mp3',
        lang: 'en');
    await db.feedsDao.insertEpisode(
        workId: o,
        feedId: feed,
        guid: 'g1',
        enclosureUrl: 'https://cast.test/1.mp3',
        publishedAtMs: 1);
    // Four paragraphs; the third has no translation (nothing to say).
    await db.spineDao.insertSegments(o, const [
      (idx: 0, kind: 'prose', text: 'Hello.'),
      (idx: 1, kind: 'prose', text: 'The boats.'),
      (idx: 2, kind: 'prose', text: '...'),
      (idx: 3, kind: 'prose', text: 'Goodbye.'),
    ]);
    await db.spineDao.insertAlignments(o, const [
      (segmentIdx: 0, tStartMs: 0, tEndMs: 10000),
      (segmentIdx: 1, tStartMs: 10000, tEndMs: 20000),
      (segmentIdx: 2, tStartMs: 20000, tEndMs: 30000),
      (segmentIdx: 3, tStartMs: 30000, tEndMs: 40000),
    ]);
    for (final (seg, text, body) in [
      (0, 'Hello.', 'Hola.'),
      (1, 'The boats.', 'Los barcos.'),
      (3, 'Goodbye.', 'Adiós.'),
    ]) {
      await db.spineDao.upsertTranslationSentence(
          workId: o,
          segmentIdx: seg,
          sentenceIdx: 0,
          lang: 'es',
          sourceText: text,
          body: body);
    }
    final v = await db.spineDao.insertWork(
        profileId: p,
        kind: 'version',
        title: 'Harbour (Spanish)',
        persistence: 'ephemeron',
        firstSeenEpochDay: 1,
        sourceUrl: 'https://spoken.trellis.invalid/$o-es.ogg',
        lang: 'es');
    await db.versionsDao.put(workId: v, originalId: o, lang: 'es');
    await db.spineDao.insertSegments(v, const [
      (idx: 0, kind: 'prose', text: 'Hola.'),
      (idx: 1, kind: 'prose', text: 'Los barcos.'),
      (idx: 2, kind: 'prose', text: 'Adiós.'),
    ]);
    await db.spineDao.insertAlignments(v, const [
      (segmentIdx: 0, tStartMs: 0, tEndMs: 2000),
      (segmentIdx: 1, tStartMs: 2000, tEndMs: 5000),
      (segmentIdx: 2, tStartMs: 5000, tEndMs: 6000),
    ]);
    original = (await db.spineDao.workById(o))!;
    es = (await db.spineDao.workById(v))!;
  });
  tearDown(() => db.close());

  test('from the episode to its Spanish: the start of the same paragraph',
      () async {
    expect(await placeIn(db, from: original, at: 15000, to: es), 2000,
        reason: 'paragraph 1 of the episode is the version’s paragraph 1');
    expect(await placeIn(db, from: original, at: 35000, to: es), 5000,
        reason: 'paragraph 3, past one with no translation');
    expect(await placeIn(db, from: original, at: 25000, to: es), 2000,
        reason: 'in an untranslated paragraph: the one before it');
  });

  test('from the Spanish back to the episode', () async {
    expect(await placeIn(db, from: es, at: 5500, to: original), 30000);
    expect(await placeIn(db, from: es, at: 100, to: original), 0);
  });

  test('the languages of an episode, from it or from any of its versions',
      () async {
    final from = await episodeLanguages(db, es);
    expect([for (final l in from) (l.lang, l.work.id)],
        [('en', original.id), ('es', es.id)]);
    expect([for (final l in await episodeLanguages(db, original)) l.lang],
        ['en', 'es']);
  });

  test('with no paragraphs to go by, the same share of the way in', () async {
    await (db.delete(db.alignments)..where((a) => a.workId.equals(es.id)))
        .go();
    expect(await placeIn(db, from: original, at: 20000, to: es), isNull,
        reason: 'the caller then keeps the share of the way in');
  });
}
