import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:trellis/db/database.dart';

import '../support/schema_strip.dart';

/// 1.5.5: a translation run in progress is written down, so a run the
/// system killed resumes when the work is opened again; and the reader's
/// old "stored Spanish means Spanish is active" guess becomes data.
void main() {
  group('the run marker', () {
    late AppDatabase db;
    late int workId;
    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      final p = await db.profilesDao.create('Ada');
      workId = await db.spineDao.insertWork(
          profileId: p,
          kind: 'article',
          title: 'A',
          persistence: 'work',
          firstSeenEpochDay: 1);
    });
    tearDown(() => db.close());

    test('is absent until a run starts, and cleared when it ends', () async {
      expect(await db.spineDao.translationRunLang(workId), isNull);
      await db.spineDao.setTranslationRunLang(workId, 'de');
      expect(await db.spineDao.translationRunLang(workId), 'de');
      await db.spineDao.setTranslationRunLang(workId, null);
      expect(await db.spineDao.translationRunLang(workId), isNull);
    });
  });

  group('schema migration v30 -> v31', () {
    test('adds the run marker and makes legacy Spanish the active '
        'translation, keeping every row', () async {
      final dir = Directory.systemTemp.createTempSync('trellis-migration-v31');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/v30.sqlite');
      final seed = AppDatabase.forTesting(NativeDatabase(file));
      final p = await seed.profilesDao.create('Ada');
      Future<int> work(String title) => seed.spineDao.insertWork(
          profileId: p,
          kind: 'article',
          title: title,
          persistence: 'work',
          firstSeenEpochDay: 1);
      // Translated to Spanish before the active slot existed.
      final legacy = await work('Legacy');
      // Spanish rows but German chosen since: the choice stands.
      final chosen = await work('Chosen');
      // Never translated.
      final plain = await work('Plain');
      for (final w in [legacy, chosen]) {
        await seed.spineDao.upsertTranslationSentence(
            workId: w,
            segmentIdx: 0,
            sentenceIdx: 0,
            lang: 'es',
            sourceText: 'Hello.',
            body: 'Hola.');
      }
      await seed.spineDao.setActiveTranslationLang(chosen, 'de');
      await seed.spineDao.setShowTranslationLayer(legacy, false);
      await seed.close();

      final v30 = raw.sqlite3.open(file.path);
      v30.execute('''
        $stripV31
        UPDATE works SET active_translation_lang = NULL WHERE id = $legacy;
        PRAGMA user_version = 30;
      ''');
      expect(
          v30
              .select("SELECT name FROM pragma_table_info('works') "
                  "WHERE name = 'translation_run_lang'")
              .isEmpty,
          isTrue);
      v30.dispose();

      final migrated = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(migrated.close);
      final dao = migrated.spineDao;
      expect(await dao.activeTranslationLang(legacy), 'es');
      expect(await dao.showTranslationLayer(legacy), isFalse,
          reason: 'only the language is filled in; a display the reader '
              'turned off stays off');
      expect(await dao.activeTranslationLang(chosen), 'de');
      expect(await dao.activeTranslationLang(plain), isNull);
      expect(
          (await dao.translationSentencesOf(legacy, lang: 'es'))[(0, 0)]!.body,
          'Hola.');
      expect(await dao.translationRunLang(legacy), isNull);
      await dao.setTranslationRunLang(plain, 'fr');
      expect(await dao.translationRunLang(plain), 'fr');
    });
  });
}
