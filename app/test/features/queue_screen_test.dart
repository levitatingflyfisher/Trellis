import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/player/queue_screen.dart';

import '../support/fake_player.dart';

/// The Queue tab: what's queued, in order, with a
/// remove verb per row and drag to reorder (the reorder LOGIC is
/// queue_db_test.dart's job — this pins what the screen shows and that
/// remove actually removes).
void main() {
  late AppDatabase db;
  late int profileId;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
  });
  tearDown(() => db.close());

  Future<int> seedWork(String title) => db.spineDao.insertWork(
      profileId: profileId,
      kind: 'episode',
      title: title,
      persistence: 'ephemeron',
      firstSeenEpochDay: 100);

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
        home: QueueScreen(
            db: db, profile: (await db.profilesDao.all()).single)));
    await tester.pumpAndSettle();
  }

  testWidgets('an empty queue is an honest, calm nothing', (tester) async {
    await pump(tester);
    expect(find.text('Nothing queued yet.'), findsOneWidget);
  });

  testWidgets('shows queued episodes in play order', (tester) async {
    final a = await seedWork('Aurora season');
    final b = await seedWork('Perseid peak');
    await db.queueDao.playLast(profileId: profileId, workId: a, nowMs: 1);
    await db.queueDao.playLast(profileId: profileId, workId: b, nowMs: 2);

    await pump(tester);

    final auroraY = tester.getTopLeft(find.text('Aurora season')).dy;
    final perseidY = tester.getTopLeft(find.text('Perseid peak')).dy;
    expect(auroraY, lessThan(perseidY));
  });

  testWidgets('removing an item takes it out of the queue', (tester) async {
    final a = await seedWork('Aurora season');
    await db.queueDao.playLast(profileId: profileId, workId: a, nowMs: 1);
    await pump(tester);

    await tester.tap(find.byKey(Key('queue-remove-$a')));
    await tester.pumpAndSettle();

    expect(find.text('Aurora season'), findsNothing);
    expect(await db.queueDao.queueOf(profileId), isEmpty);
  });

  testWidgets('a change of what is playing reloads the list: the tab can '
      'be on screen while an episode finishes and leaves the queue',
      (tester) async {
    final a = await seedWork('Aurora season');
    final player = PlayerController(
        db: db, profileId: profileId, createPlayer: FakeEpisodePlayer.new);
    addTearDown(player.dispose);
    await db.queueDao.playLast(profileId: profileId, workId: a, nowMs: 1);
    await tester.pumpWidget(MaterialApp(
        home: QueueScreen(
            db: db,
            profile: (await db.profilesDao.all()).single,
            player: player)));
    await tester.pumpAndSettle();
    expect(find.text('Aurora season'), findsOneWidget);

    // What the finish law does: the queue loses the episode, then the
    // player moves on.
    await db.queueDao.remove(profileId: profileId, workId: a);
    final b = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Perseid peak',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/p.mp3');
    await player.playWork((await db.spineDao.workById(b))!);
    await tester.pumpAndSettle();

    expect(find.text('Aurora season'), findsNothing);
  });
}
