import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/scripted_fetcher.dart';

/// ADR-0003 law 2 wired at the app's boot: decayed ephemera leave before
/// anything renders; anything the user's hand touched persists.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  int todayEpochDay() =>
      DateTime.now().toUtc().millisecondsSinceEpoch ~/
      Duration.millisecondsPerDay;

  testWidgets('boot sweeps decayed ephemera, keeps fresh and promoted ones',
      (tester) async {
    final profileId = await db.profilesDao.create('Ada');
    final feedId = await db.feedsDao
        .insertFeed(profileId: profileId, url: 'https://cast.test/feed');
    final today = todayEpochDay();

    Future<int> seed(String title, int firstSeen,
        {String persistence = 'ephemeron'}) async {
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: title,
          persistence: persistence,
          firstSeenEpochDay: firstSeen);
      await db.feedsDao.insertEpisode(
          workId: workId,
          feedId: feedId,
          guid: title,
          publishedAtMs: firstSeen);
      return workId;
    }

    await seed('Decayed', today - 31);
    await seed('Boundary', today - 30); // the boundary day itself survives
    await seed('Fresh', today - 1);
    final promoted = await seed('Promoted long ago', today - 200);
    await db.spineDao.promoteWork(promoted);

    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((u, h) => textResponse('')),
        createPlayer: () => FakeEpisodePlayer()));
    await tester.pumpAndSettle();

    final titles =
        (await db.spineDao.worksOf(profileId)).map((w) => w.title).toList();
    expect(titles, ['Boundary', 'Fresh', 'Promoted long ago']);
    // The decayed one's river row went with it (no orphaned episode rows).
    expect(await db.feedsDao.riverItems(profileId), hasLength(3));
  });
}
