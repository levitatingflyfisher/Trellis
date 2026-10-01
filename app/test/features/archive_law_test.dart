import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/tabs.dart';
import '../support/scripted_fetcher.dart';
import '../support/pick_reader.dart';

/// ADR-0019, the law that replaced ADR-0003 law 2: nothing decays. Latest
/// is a permanent archive, so an item older than any retention window the
/// app ever had is still listed after a full boot.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  int todayEpochDay() =>
      DateTime.now().toUtc().millisecondsSinceEpoch ~/
      Duration.millisecondsPerDay;

  testWidgets('an item first seen years ago is still in Latest after boot',
      (tester) async {
    final profileId = await db.profilesDao.create('Ada');
    final feedId = await db.feedsDao
        .insertFeed(profileId: profileId, url: 'https://cast.test/feed');
    final today = todayEpochDay();
    Future<void> seed(String title, int firstSeen) async {
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'article',
          title: title,
          persistence: 'ephemeron',
          firstSeenEpochDay: firstSeen);
      await db.feedsDao.insertEpisode(
          workId: workId,
          feedId: feedId,
          guid: title,
          publishedAtMs: firstSeen * Duration.millisecondsPerDay);
    }

    await seed('Years old', today - 1000);
    await seed('Fresh', today);

    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((u, h) => textResponse('')),
        createPlayer: () => FakeEpisodePlayer()));
    await tester.pumpAndSettle();
    await pickReader(tester, 'Ada');
    await tester.tap(tabLabel('Latest'));
    await tester.pumpAndSettle();

    expect(find.text('Years old'), findsOneWidget);
    expect(
        (await db.feedsDao.riverItems(profileId)).map((e) => e.work.title),
        ['Fresh', 'Years old']);
    expect((await db.spineDao.workById(1))!.persistence, 'ephemeron',
        reason: 'boot changes nothing about an item nobody touched');
  });
}
