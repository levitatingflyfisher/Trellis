import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:trellis/db/database.dart';

/// The spine's storage contract (ADR-0002): positions are one tiny row,
/// layers are per-segment, ephemera carry their sovereignty bit.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('a position save is a single-row upsert, not a work rewrite', () async {
    final profileId = await db.profilesDao.create('Ada');
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Ep 1',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100);

    await db.spineDao.savePosition(
        profileId: profileId, workId: workId, segmentIdx: 4, wordIdx: 2, lastModality: 'listen');
    await db.spineDao.savePosition(
        profileId: profileId, workId: workId, segmentIdx: 7, wordIdx: 0, lastModality: 'read');

    final pos = await db.spineDao.position(profileId: profileId, workId: workId);
    expect(pos!.segmentIdx, 7);
    expect(pos.wordIdx, 0);
    final all = await db.spineDao.allPositions();
    expect(all.length, 1, reason: 'upsert, never a second row per work');
  });

  test('segments and per-language layers round-trip in order', () async {
    final profileId = await db.profilesDao.create('Ada');
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Ep 1',
        persistence: 'work',
        firstSeenEpochDay: 100);
    await db.spineDao.insertSegments(workId, const [
      (idx: 0, kind: 'prose', text: 'Hola.'),
      (idx: 1, kind: 'prose', text: 'Adiós.'),
    ]);
    await db.spineDao.insertLayers(workId, const [
      (segmentIdx: 0, lang: 'en', kind: 'mt', text: 'Hello.'),
    ]);

    final segs = await db.spineDao.segmentsOf(workId);
    expect(segs.map((s) => s.body), ['Hola.', 'Adiós.']);
    final layers = await db.spineDao.layersOf(workId, lang: 'en');
    expect(layers.single.body, 'Hello.');
  });

  test('deleting a work cascades its segments, layers, positions, and translation sentences', () async {
    final profileId = await db.profilesDao.create('Ada');
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'article',
        title: 'A',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100);
    await db.spineDao.insertSegments(workId, const [(idx: 0, kind: 'prose', text: 'x')]);
    await db.spineDao.savePosition(
        profileId: profileId, workId: workId, segmentIdx: 0, wordIdx: 0, lastModality: 'read');
    await db.spineDao.upsertTranslationSentence(
        workId: workId,
        segmentIdx: 0,
        sentenceIdx: 0,
        lang: 'es',
        sourceText: 'x',
        body: 'y');

    await db.spineDao.deleteWork(workId);
    expect(await db.spineDao.segmentsOf(workId), isEmpty);
    expect(await db.spineDao.allPositions(), isEmpty);
    expect(await db.spineDao.translationSentencesOf(workId, lang: 'es'), isEmpty);
  });

  group('translation sentences (ADR-0008 "Babel" Phase 3)', () {
    test('upsert is idempotent by (workId, segmentIdx, sentenceIdx, lang)', () async {
      final profileId = await db.profilesDao.create('Ada');
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'article',
          title: 'A',
          persistence: 'work',
          firstSeenEpochDay: 100);
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: 'es',
          sourceText: 'Hello.',
          body: 'Hola.');
      // A re-run of the same unit (a retry, or a resumed job re-executing
      // the same unit) overwrites, never duplicates.
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: 'es',
          sourceText: 'Hello.',
          body: 'Hola de nuevo.');
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 0,
          sentenceIdx: 1,
          lang: 'es',
          sourceText: 'How are you?',
          body: '¿Cómo estás?');

      final sentences = await db.spineDao.translationSentencesOf(workId, lang: 'es');
      expect(sentences.length, 2, reason: 'overwrite, not a duplicate row');
      expect(sentences[(0, 0)]!.body, 'Hola de nuevo.');
      expect(sentences[(0, 0)]!.sourceText, 'Hello.');
      expect(sentences[(0, 1)]!.body, '¿Cómo estás?');
    });

    test('hasTranslationSentences and the per-work display toggle', () async {
      final profileId = await db.profilesDao.create('Ada');
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'article',
          title: 'A',
          persistence: 'work',
          firstSeenEpochDay: 100);

      expect(await db.spineDao.hasTranslationSentences(workId, lang: 'es'), isFalse);
      expect(await db.spineDao.showTranslationLayer(workId), isFalse,
          reason: 'off by default, see Works.showTranslationLayer');

      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: 'es',
          sourceText: 'Hi.',
          body: 'Hola.');
      expect(await db.spineDao.hasTranslationSentences(workId, lang: 'es'), isTrue);
      // A different language a work has no rows for is unaffected.
      expect(await db.spineDao.hasTranslationSentences(workId, lang: 'fr'), isFalse);

      await db.spineDao.setShowTranslationLayer(workId, true);
      expect(await db.spineDao.showTranslationLayer(workId), isTrue);
      await db.spineDao.setShowTranslationLayer(workId, false);
      expect(await db.spineDao.showTranslationLayer(workId), isFalse);
    });
  });

  group('schema migration v12 → v13', () {
    test('a v12 database gains the translation layer and keeps its data',
        () async {
      final dir = Directory.systemTemp.createTempSync('trellis-migration-v13');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/v12.sqlite');

      // Build a real v12 file from drift's own DDL: create at the current
      // version, drop exactly what v13 (this campaign's own hop) added,
      // stamp user_version 12. v13 is purely additive, so what remains IS
      // the v12 schema — whatever v12 itself turns out to contain (v12 is
      // player-love's hop, landing separately; this test only proves v13's
      // OWN migration is correct given ANY database already at v12, per
      // the two campaigns' independent guards). `translation_sentences`
      // is a brand-new table so its own creation is idempotent either
      // way, but `works.show_translation_layer` is an `addColumn` and
      // must go, or a database claiming to be v12 would silently already
      // carry it.
      final seed = AppDatabase.forTesting(NativeDatabase(file));
      final profileId = await seed.profilesDao.create('Ada');
      final workId = await seed.spineDao.insertWork(
          profileId: profileId,
          kind: 'book',
          title: 'Kept Book',
          persistence: 'work',
          firstSeenEpochDay: 100);
      await seed.close();
      final v12 = raw.sqlite3.open(file.path);
      v12.execute('''
        DROP TABLE translation_sentences;
        DROP TABLE saved_views;
        ALTER TABLE works DROP COLUMN show_translation_layer;
        ALTER TABLE feeds DROP COLUMN rules_json;
        ALTER TABLE episodes DROP COLUMN dedup_reason;
        ALTER TABLE episodes DROP COLUMN duplicate_of_work_id;
        ALTER TABLE feeds DROP COLUMN dsp_enabled;
        ALTER TABLE episodes DROP COLUMN dsp_original_duration_ms;
        ALTER TABLE episodes DROP COLUMN dsp_processed_duration_ms;
        ALTER TABLE profiles DROP COLUMN dsp_global_default;
        DROP TABLE audiobook_files;
        DROP TABLE audiobooks;
        ALTER TABLE player_positions DROP COLUMN file_idx;
        ALTER TABLE captures DROP COLUMN file_idx;
        ALTER TABLE profiles DROP COLUMN reader_prefs_json;
        DROP TABLE reading_days;
        PRAGMA user_version = 12;
      ''');
      v12.dispose();

      final migrated = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(migrated.close);

      // Old data survives…
      final work = (await migrated.spineDao.worksOf(profileId)).single;
      expect(work.title, 'Kept Book');

      // …the toggle defaults false…
      expect(await migrated.spineDao.showTranslationLayer(workId), isFalse);

      // …and the new table works.
      await migrated.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: 'es',
          sourceText: 'Hi.',
          body: 'Hola.');
      final sentences =
          await migrated.spineDao.translationSentencesOf(workId, lang: 'es');
      expect(sentences[(0, 0)]!.body, 'Hola.');
    });
  });

  test('the ephemera sweep deletes exactly the pure verdict, promoted works survive', () async {
    final profileId = await db.profilesDao.create('Ada');
    await db.spineDao.insertWork(
        profileId: profileId, kind: 'episode', title: 'old',
        persistence: 'ephemeron', firstSeenEpochDay: 100);
    final kept = await db.spineDao.insertWork(
        profileId: profileId, kind: 'episode', title: 'kept',
        persistence: 'ephemeron', firstSeenEpochDay: 100);
    await db.spineDao.promoteWork(kept);

    final swept = await db.spineDao.sweepEphemera(todayEpochDay: 131);
    expect(swept, 1);
    final titles = (await db.spineDao.worksOf(profileId)).map((w) => w.title);
    expect(titles, ['kept']);
  });
}
