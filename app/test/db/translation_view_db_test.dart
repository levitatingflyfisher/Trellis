import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:trellis/db/database.dart';

import '../support/schema_strip.dart';

/// 1.5.8: how a work's translation shows — beside the original ("Both",
/// the default) or in its place ("Translation only") — is remembered per
/// work, like the language the work page opens it in.
void main() {
  test('Both until Translation only is chosen, and back', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final p = await db.profilesDao.create('Ada');
    final w = await db.spineDao.insertWork(
        profileId: p,
        kind: 'article',
        title: 'A',
        persistence: 'work',
        firstSeenEpochDay: 1);
    expect(await db.spineDao.translationOnly(w), isFalse);
    await db.spineDao.setTranslationOnly(w, true);
    expect(await db.spineDao.translationOnly(w), isTrue);
    await db.spineDao.setTranslationOnly(w, false);
    expect(await db.spineDao.translationOnly(w), isFalse);
  });

  test('schema migration v31 -> v32 adds the column, keeping every row',
      () async {
    final dir = Directory.systemTemp.createTempSync('trellis-migration-v32');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/v31.sqlite');
    final seed = AppDatabase.forTesting(NativeDatabase(file));
    final p = await seed.profilesDao.create('Ada');
    final w = await seed.spineDao.insertWork(
        profileId: p,
        kind: 'article',
        title: 'Kept',
        persistence: 'work',
        firstSeenEpochDay: 1);
    await seed.spineDao.setActiveTranslationLang(w, 'de');
    await seed.close();

    final v31 = raw.sqlite3.open(file.path);
    v31.execute('$stripV32\nPRAGMA user_version = 31;');
    v31.dispose();

    final migrated = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(migrated.close);
    expect((await migrated.spineDao.workById(w))!.title, 'Kept');
    expect(await migrated.spineDao.activeTranslationLang(w), 'de');
    expect(await migrated.spineDao.translationOnly(w), isFalse);
    await migrated.spineDao.setTranslationOnly(w, true);
    expect(await migrated.spineDao.translationOnly(w), isTrue);
  });
}
