import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/bootstrap/bootstrap_io.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/search/search_store.dart';

/// Searches run on a reading connection (1.5.4): a refresh's write
/// transaction, which on the phone can stay open for seconds, never holds
/// one up. Through the app's own opener, on a real file under WAL.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('trellis-read-pool'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('a search during an open write transaction answers at once',
      () async {
    final db = AppDatabase(openNativeConnection(File('${dir.path}/t.sqlite')));
    addTearDown(db.close);
    final p = await db.profilesDao.create('Ada');
    final w = await db.spineDao.insertWork(
        profileId: p,
        kind: 'book',
        title: 'Aurora season',
        persistence: 'work',
        firstSeenEpochDay: 1);
    final store = SearchStore(db);
    await store.search(p, 'aurora'); // warm: the readers are open

    final inside = Completer<void>();
    final release = Completer<void>();
    final writing = db.transaction(() async {
      await db.customStatement('UPDATE works SET pinned = pinned');
      inside.complete();
      await release.future;
    });
    await inside.future;
    final watch = Stopwatch()..start();
    final r = await store
        .search(p, 'aurora')
        .timeout(const Duration(seconds: 5));
    watch.stop();
    release.complete();
    await writing;
    expect([for (final i in r.items) i.work.id], [w]);
    expect(watch.elapsedMilliseconds, lessThan(100));
  });

  test('a row written outside a transaction is read back at once', () async {
    final db = AppDatabase(openNativeConnection(File('${dir.path}/t.sqlite')));
    addTearDown(db.close);
    final p = await db.profilesDao.create('Ada');
    final f = await db.feedsDao.insertFeed(profileId: p, url: 'f');
    final w = await db.spineDao.insertWork(
        profileId: p,
        kind: 'episode',
        title: 'E',
        persistence: 'ephemeron',
        firstSeenEpochDay: 1);
    expect(
        await db.feedsDao
            .insertEpisodeIfNew(workId: w, feedId: f, guid: 'g', publishedAtMs: 1),
        isTrue);
    expect(
        await db.feedsDao
            .insertEpisodeIfNew(workId: w, feedId: f, guid: 'g', publishedAtMs: 1),
        isFalse);
    expect(await db.feedsDao.guidsOf(f), {'g'});
  });
}
