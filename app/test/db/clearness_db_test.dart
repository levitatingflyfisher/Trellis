import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:trellis/db/database.dart';

import '../support/schema_strip.dart';

/// A made episode stores how clearly it was spoken (How clearly the voice
/// speaks), so the one tap can tell an episode made at another step and
/// offer to make it again at the one chosen now.
void main() {
  test('schema migration v34 -> v35 adds the column, keeping every row',
      () async {
    final dir = Directory.systemTemp.createTempSync('trellis-migration-v35');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/v34.sqlite');
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
        voiceKind: 'machine',
        publishedAtMs: 1);
    await seed.close();

    final v34 = raw.sqlite3.open(file.path);
    v34.execute('$stripV35\nPRAGMA user_version = 34;');
    v34.dispose();

    final migrated = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(migrated.close);
    final ep = (await migrated.feedsDao.episodeOf(w))!;
    expect(ep.guid, 'spoken:1:es');
    expect(ep.voiceKind, 'machine');
    expect(ep.clearness, isNull,
        reason: 'made before the step was stored: every episode then was '
            'spoken at the voice’s own pace, which null reads as');
    await (migrated.update(migrated.episodes)
          ..where((e) => e.workId.equals(w)))
        .write(const EpisodesCompanion(clearness: Value('slow')));
    expect((await migrated.feedsDao.episodeOf(w))!.clearness, 'slow');
  });
}
