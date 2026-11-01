import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:trellis/db/database.dart';

import '../support/schema_strip.dart';

/// A made episode stores the kind of voice that said it (1.6.x): Share
/// reads it to keep a real host's cloned voice behind its own switch,
/// rather than reading it back out of the episode's words.
void main() {
  test('schema migration v32 -> v33 adds the column, keeping every row',
      () async {
    final dir = Directory.systemTemp.createTempSync('trellis-migration-v33');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/v32.sqlite');
    final seed = AppDatabase.forTesting(NativeDatabase(file));
    final p = await seed.profilesDao.create('Ada');
    final feed = await seed.feedsDao
        .insertFeed(profileId: p, url: 'https://cast.test/f', title: 'Show');
    final w = await seed.spineDao.insertWork(
        profileId: p,
        kind: 'episode',
        title: 'Kept',
        persistence: 'ephemeron',
        firstSeenEpochDay: 1);
    await seed.feedsDao.insertEpisode(
        workId: w,
        feedId: feed,
        guid: 'spoken:1:es',
        enclosureUrl: 'https://spoken.trellis.invalid/1-es.ogg',
        publishedAtMs: 1);
    await seed.close();

    final v32 = raw.sqlite3.open(file.path);
    v32.execute('$stripV33\nPRAGMA user_version = 32;');
    v32.dispose();

    final migrated = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(migrated.close);
    final ep = (await migrated.feedsDao.episodeOf(w))!;
    expect(ep.guid, 'spoken:1:es');
    expect(ep.voiceKind, isNull,
        reason: 'made before the kind was stored: every voice then was '
            'a machine voice, and Share treats null as one');
    await (migrated.update(migrated.episodes)
          ..where((e) => e.workId.equals(w)))
        .write(const EpisodesCompanion(voiceKind: Value('cloned')));
    expect((await migrated.feedsDao.episodeOf(w))!.voiceKind, 'cloned');
  });
}
