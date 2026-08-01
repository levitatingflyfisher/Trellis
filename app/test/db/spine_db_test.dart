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
    test('the store round-trips a non-es language cleanly — nothing es-'
        'specific leaked into the queries (Campaign 8 "Babel widens" '
        'Phase 1)', () async {
      final profileId = await db.profilesDao.create('Ada');
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'article',
          title: 'A',
          persistence: 'work',
          firstSeenEpochDay: 100,
          lang: 'de');
      // Three different languages for the SAME work — proves `lang` is a
      // real key component, not an implicit constant somewhere.
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: 'ru',
          sourceText: 'Hallo.',
          body: 'Привет.',
          engine: 'marian');
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: 'zh',
          sourceText: 'Hallo.',
          body: '你好。',
          engine: 'marian');
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: 'es',
          sourceText: 'Hallo.',
          body: 'Hola.',
          engine: 'marian');

      final ru = await db.spineDao.translationSentencesOf(workId, lang: 'ru');
      final zh = await db.spineDao.translationSentencesOf(workId, lang: 'zh');
      final es = await db.spineDao.translationSentencesOf(workId, lang: 'es');
      expect(ru[(0, 0)]!.body, 'Привет.');
      expect(zh[(0, 0)]!.body, '你好。');
      expect(es[(0, 0)]!.body, 'Hola.');
      // Each language's row is genuinely independent — writing 'es' did
      // not disturb 'ru' or 'zh', and each keeps its own row count.
      expect(ru.length, 1);
      expect(zh.length, 1);
      expect(es.length, 1);

      expect(await db.spineDao.hasTranslationSentences(workId, lang: 'ru'),
          isTrue);
      expect(await db.spineDao.hasTranslationSentences(workId, lang: 'ja'),
          isFalse,
          reason: 'a language with no rows at all reads honestly false');
    });

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

    test('activeTranslationLang: null by default, set/clear keep the '
        'legacy show-toggle in sync — "one active layer at a time" made '
        'literal (Campaign 8 "Babel widens" Phase 1)', () async {
      final profileId = await db.profilesDao.create('Ada');
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'article',
          title: 'A',
          persistence: 'work',
          firstSeenEpochDay: 100);

      expect(await db.spineDao.activeTranslationLang(workId), isNull);

      await db.spineDao.setActiveTranslationLang(workId, 'de');
      expect(await db.spineDao.activeTranslationLang(workId), 'de');
      expect(await db.spineDao.showTranslationLayer(workId), isTrue,
          reason: 'setActiveTranslationLang turns the legacy toggle on '
              'too — nothing that still reads showTranslationLayer alone '
              'breaks');

      // Switching to a different language REPLACES the slot — there is
      // exactly one, never a set of simultaneously-active languages.
      await db.spineDao.setActiveTranslationLang(workId, 'zh');
      expect(await db.spineDao.activeTranslationLang(workId), 'zh');

      await db.spineDao.clearActiveTranslationLang(workId);
      expect(await db.spineDao.activeTranslationLang(workId), isNull);
      expect(await db.spineDao.showTranslationLayer(workId), isFalse);
    });
  });

  group('Works.lang — the declared source language (Campaign 8 "Babel '
      'widens" Phase 1)', () {
    test('setWorkLang persists and is readable back through worksOf',
        () async {
      final profileId = await db.profilesDao.create('Ada');
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'article',
          title: 'A',
          persistence: 'work',
          firstSeenEpochDay: 100);
      // No language declared at intake time (most intake paths never set
      // one — see docs/reference/mt-models.md) reads back null; callers
      // treat that as 'en' (the spec's declared default), a UI-layer
      // convention, not a DB-layer one, so a work genuinely undeclared
      // stays honestly null in storage.
      expect((await db.spineDao.worksOf(profileId)).single.lang, isNull);

      await db.spineDao.setWorkLang(workId, 'de');
      expect((await db.spineDao.worksOf(profileId)).single.lang, 'de');

      await db.spineDao.setWorkLang(workId, 'en');
      expect((await db.spineDao.worksOf(profileId)).single.lang, 'en');
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
        ALTER TABLE feeds DROP COLUMN image_url;
        DROP TABLE translation_sentences;
        DROP TABLE saved_views;
        ALTER TABLE works DROP COLUMN show_translation_layer;
        ALTER TABLE works DROP COLUMN active_translation_lang;
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

  group('schema migration v18 → v19 (Campaign 8 "Babel widens" Phase 5)', () {
    test('a v18 database gains translation_sentences.engine, defaults '
        'existing rows to null, and keeps its data', () async {
      final dir = Directory.systemTemp.createTempSync('trellis-migration-v19');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/v18.sqlite');

      // v19 is purely additive (one addColumn), guarded `from >= 13 &&
      // from < 19` — unlike v13's own hop, `translation_sentences` is
      // NOT dropped here: it's created FRESH by drift's onCreate at the
      // current schema (which already carries `engine`), so what needs
      // stripping is exactly the one column v19 added, not the table.
      // Also strips feeds.image_url (Campaign 9's v20, unknown to this
      // test when it was first written) — a genuine v18 database has
      // neither, and the migrated instance below runs the full chain to
      // the CURRENT schema version, not just to v19.
      final seed = AppDatabase.forTesting(NativeDatabase(file));
      final profileId = await seed.profilesDao.create('Ada');
      final workId = await seed.spineDao.insertWork(
          profileId: profileId,
          kind: 'book',
          title: 'Kept Book',
          persistence: 'work',
          firstSeenEpochDay: 100);
      await seed.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: 'es',
          sourceText: 'Hi.',
          body: 'Hola.');
      await seed.close();
      final v18 = raw.sqlite3.open(file.path);
      v18.execute('''
        ALTER TABLE translation_sentences DROP COLUMN engine;
        ALTER TABLE works DROP COLUMN active_translation_lang;
        ALTER TABLE feeds DROP COLUMN image_url;
        PRAGMA user_version = 18;
      ''');
      v18.dispose();

      final migrated = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(migrated.close);

      // Old data survives…
      final work = (await migrated.spineDao.worksOf(profileId)).single;
      expect(work.title, 'Kept Book');
      final existing =
          await migrated.spineDao.translationSentencesOf(workId, lang: 'es');
      expect(existing[(0, 0)]!.body, 'Hola.');
      // …a pre-v19 row reads `engine` as null, not a thrown error…
      expect(existing[(0, 0)]!.engine, isNull);
      // …Works.activeTranslationLang reads null too, and is settable…
      expect(await migrated.spineDao.activeTranslationLang(workId), isNull);
      await migrated.spineDao.setActiveTranslationLang(workId, 'de');
      expect(await migrated.spineDao.activeTranslationLang(workId), 'de');

      // …and a NEW row can stamp provenance.
      await migrated.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 0,
          sentenceIdx: 1,
          lang: 'es',
          sourceText: 'Bye.',
          body: 'Adiós.',
          engine: 'marian');
      final after =
          await migrated.spineDao.translationSentencesOf(workId, lang: 'es');
      expect(after[(0, 1)]!.engine, 'marian');
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
