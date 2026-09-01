import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/scripted_fetcher.dart';
import '../support/pick_reader.dart';

/// ADR-0003 law 2 wired at the app's boot: decayed ephemera leave the river
/// before anything renders; anything the user's hand touched persists. The
/// leaving is never silent and never final on its own: decayed items stay
/// recoverable, and the River says so in one line until the user either
/// restores them or lets them go (operator ruling: data loss is recoverable).
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

    // Out of the river...
    expect(
        (await db.feedsDao.riverItems(profileId)).map((e) => e.work.title),
        ['Fresh', 'Boundary', 'Promoted long ago']);
    // ...but not out of the database: nothing was deleted at boot.
    expect((await db.spineDao.decayedOf(profileId)).map((w) => w.title),
        ['Decayed']);
  });

  Future<int> seedDecayedOnly(int count) async {
    final profileId = await db.profilesDao.create('Ada');
    final feedId = await db.feedsDao
        .insertFeed(profileId: profileId, url: 'https://cast.test/feed');
    final today = todayEpochDay();
    for (var i = 0; i < count; i++) {
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'article',
          title: 'Old $i',
          persistence: 'ephemeron',
          firstSeenEpochDay: today - 40);
      await db.feedsDao.insertEpisode(
          workId: workId, feedId: feedId, guid: 'g$i', publishedAtMs: i);
    }
    return profileId;
  }

  Future<void> openRiver(WidgetTester tester) async {
    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((u, h) => textResponse('')),
        createPlayer: () => FakeEpisodePlayer()));
    await tester.pumpAndSettle();
    await pickReader(tester, 'Ada');
    await tester.tap(find.text('Inbox'));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'after a fortnight away the empty River still says what left, and '
      'Restore brings it all back', (tester) async {
    final profileId = await seedDecayedOnly(2);
    await openRiver(tester);

    final notice = find.byKey(const Key('river-decayed-notice'));
    expect(notice, findsOneWidget,
        reason: 'the empty state must not swallow the notice');
    expect(
        find.descendant(
            of: notice,
            matching: find.textContaining('2 items older than 30 days')),
        findsOneWidget);

    await tester.tap(find.byKey(const Key('river-decayed-restore')));
    await tester.pumpAndSettle();
    expect(notice, findsNothing);
    expect(find.text('Old 0'), findsOneWidget);
    expect(find.text('Old 1'), findsOneWidget);
    expect(await db.spineDao.decayedOf(profileId), isEmpty);
  });

  testWidgets('Let go is the one gesture that deletes, and the notice goes',
      (tester) async {
    final profileId = await seedDecayedOnly(1);
    await openRiver(tester);

    expect(find.textContaining('1 item older than 30 days'), findsOneWidget);
    await tester.tap(find.byKey(const Key('river-decayed-purge')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('river-decayed-notice')), findsNothing);
    expect(await db.spineDao.worksOf(profileId), isEmpty);
  });

  testWidgets('with nothing decayed there is no notice at all',
      (tester) async {
    await seedDecayedOnly(0);
    await openRiver(tester);
    expect(find.byKey(const Key('river-decayed-notice')), findsNothing);
  });
}
