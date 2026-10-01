import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/reader/reader_screen.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/pick_reader.dart';
import '../support/scripted_fetcher.dart';
import '../support/tabs.dart';

/// A podcast is readable without being played: Read on a transcribed
/// episode's row opens its transcript on Page, whatever is playing.
void main() {
  late AppDatabase db;
  late FakeEpisodePlayer fakePlayer;
  late PlayerController controller;
  late int profileId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    fakePlayer = FakeEpisodePlayer();
    profileId = await db.profilesDao.create('Ada');
    controller = PlayerController(
        db: db, profileId: profileId, createPlayer: () => fakePlayer);
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
  });

  group('Read on an episode row', () {
    Future<int> seedFeedEpisode({required bool transcribed}) async {
      final feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://cast.test/feed');
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: 'Ep 1',
          persistence: 'ephemeron',
          firstSeenEpochDay: 100,
          sourceUrl: 'https://cast.test/1.mp3');
      await db.feedsDao.insertEpisode(
          workId: workId,
          feedId: feedId,
          guid: 'g1',
          publishedAtMs: 1000,
          enclosureUrl: 'https://cast.test/1.mp3');
      if (transcribed) {
        await db.spineDao.insertSegments(workId, const [
          (idx: 0, kind: 'prose', text: 'First sentence.'),
          (idx: 1, kind: 'prose', text: 'Second sentence.'),
        ]);
        await db.spineDao.insertAlignments(workId, const [
          (segmentIdx: 0, tStartMs: 0, tEndMs: 10000),
          (segmentIdx: 1, tStartMs: 10000, tEndMs: 20000),
        ]);
      }
      return workId;
    }

    Future<FakeEpisodePlayer> openLatest(WidgetTester tester) async {
      final player = FakeEpisodePlayer();
      await tester.pumpWidget(TrellisApp(
          db: db,
          fetcher: ScriptedFetcher((u, h) => textResponse('')),
          createPlayer: () => player));
      await tester.pumpAndSettle();
      await pickReader(tester, 'Ada');
      await toTab(tester, 'Latest');
      return player;
    }

    testWidgets('only a transcribed episode offers Read', (tester) async {
      final id = await seedFeedEpisode(transcribed: false);
      await openLatest(tester);
      expect(find.byKey(Key('play-$id')), findsOneWidget);
      expect(find.byKey(Key('read-$id')), findsNothing);
    });

    // 1.5.5: Read opens Page, the reader, which replaced this view.
    testWidgets('Read opens the transcript on Page without playing, and its '
        'Play plays', (tester) async {
      final id = await seedFeedEpisode(transcribed: true);
      final player = await openLatest(tester);

      expect(find.byTooltip('Read transcript'), findsOneWidget);
      await tester.tap(find.byKey(Key('read-$id')));
      await tester.pumpAndSettle();

      expect(find.byType(ReaderScreen), findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(const Key('mode-toggle')),
              matching: find.text('Page')),
          findsOneWidget);
      expect(find.text('Second'), findsOneWidget);
      expect(player.loadedUrl, isNull, reason: 'reading plays nothing');

      await tester.tap(find.byKey(const Key('reader-play')));
      await tester.pumpAndSettle();
      expect(player.loadedUrl, 'https://cast.test/1.mp3');
    });
  });
}
