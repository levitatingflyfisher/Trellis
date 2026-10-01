import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show kPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/player/queue_screen.dart';
import 'package:trellis/features/works/work_row.dart';

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

    // A screen's own item, plainly labelled, at the end of the row's menu.
    await tester.tap(find.byKey(Key('menu-$a')));
    await tester.pumpAndSettle();
    expect(find.text('Remove from Queue'), findsOneWidget);
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

  group('the shared row', () {
    late int feedId;
    setUp(() async {
      feedId = await db.feedsDao.insertFeed(
          profileId: profileId, url: 'https://x.test/f', title: 'Night Sky');
    });

    Future<int> seedEpisode(String title, {bool transcribed = false}) async {
      final id = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: title,
          persistence: 'ephemeron',
          firstSeenEpochDay: 100,
          sourceUrl: 'https://x.test/$title.mp3');
      await db.feedsDao.insertEpisode(
          workId: id,
          feedId: feedId,
          guid: title,
          enclosureUrl: 'https://x.test/$title.mp3',
          durationMs: 45 * 60000,
          publishedAtMs: DateTime(2026, 8, 5).millisecondsSinceEpoch);
      if (transcribed) {
        await db.spineDao
            .insertSegments(id, [(idx: 0, kind: 'prose', text: 'Hello.')]);
        await db.spineDao.insertAlignments(
            id, [(segmentIdx: 0, tStartMs: 0, tEndMs: 1000)]);
      }
      return id;
    }

    Future<void> pumpWithPlayer(WidgetTester tester) async {
      final player = PlayerController(
          db: db, profileId: profileId, createPlayer: FakeEpisodePlayer.new);
      addTearDown(player.dispose);
      await tester.pumpWidget(MaterialApp(
          home: QueueScreen(
              db: db,
              profile: (await db.profilesDao.all()).single,
              player: player)));
      await tester.pumpAndSettle();
    }

    testWidgets('each queued work is the same row as anywhere else, with '
        'the show, the day and the length', (tester) async {
      final a = await seedEpisode('Aurora');
      await db.queueDao.playLast(profileId: profileId, workId: a, nowMs: 1);
      await pumpWithPlayer(tester);
      expect(find.byType(WorkRow), findsOneWidget);
      expect(find.text('Night Sky · 5 Aug · 45\u00A0min'), findsOneWidget);
      expect(find.byKey(Key('play-$a')), findsOneWidget);
      expect(find.text('In Queue'), findsNothing,
          reason: 'every row here is queued; saying so is noise');
    });

    testWidgets('Read is on a transcribed episode and on a text work',
        (tester) async {
      final ep = await seedEpisode('Aurora', transcribed: true);
      final text = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'article',
          title: 'On tides',
          persistence: 'work',
          firstSeenEpochDay: 100,
          sourceUrl: 'https://essays.example/tides');
      await db.spineDao
          .insertSegments(text, [(idx: 0, kind: 'prose', text: 'Water.')]);
      await db.queueDao.playLast(profileId: profileId, workId: ep, nowMs: 1);
      await db.queueDao.playLast(profileId: profileId, workId: text, nowMs: 2);
      await pumpWithPlayer(tester);
      expect(find.byKey(Key('read-$ep')), findsOneWidget);
      expect(find.byKey(Key('read-$text')), findsOneWidget);
      expect(find.byKey(Key('play-$text')), findsNothing);
    });

    testWidgets('dragging a row by its handle reorders the queue',
        (tester) async {
      final a = await seedEpisode('Aurora');
      final b = await seedEpisode('Perseid');
      final c = await seedEpisode('Leonid');
      for (final (i, id) in [a, b, c].indexed) {
        await db.queueDao.playLast(profileId: profileId, workId: id, nowMs: i);
      }
      await pumpWithPlayer(tester);

      final handle = find.byKey(Key('queue-handle-$c'));
      expect(handle, findsOneWidget);
      final rowHeight =
          tester.getSize(find.byKey(Key('queue-item-$a'))).height;
      final drag = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(kPressTimeout);
      for (var i = 0; i < 10; i++) {
        await drag.moveBy(Offset(0, -rowHeight * 2.5 / 10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await drag.up();
      await tester.pumpAndSettle();

      final order = (await db.queueDao.queueOf(profileId)).map((r) => r.workId);
      expect(order, [c, a, b]);
      final cY = tester.getTopLeft(find.text('Leonid')).dy;
      final aY = tester.getTopLeft(find.text('Aurora')).dy;
      expect(cY, lessThan(aY));
    });
  });
}
