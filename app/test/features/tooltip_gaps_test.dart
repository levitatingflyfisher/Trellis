import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/feeds/feeds_repository.dart';
import 'package:trellis/features/feeds/feeds_screen.dart';
import 'package:trellis/features/library/library_screen.dart';
import 'package:trellis/features/player/mini_player_bar.dart';
import 'package:trellis/features/player/player_controller.dart';

import '../support/fake_player.dart';
import '../support/scripted_fetcher.dart';

/// Campaign 9 Phase 1 — user: "the buttons are non-obvious… the nav
/// buttons on the bottom are the only ones with names". Four spots with an
/// icon-only affordance and no `tooltip:` at all — this pins each one gets
/// a name a long-press/hover reveals. (Not a visual check: `tooltip` on
/// PopupMenuButton and IconButton is read straight off the widget, and a
/// wrapping `Tooltip`'s `message` the same way — no golden needed for
/// text that isn't rendered until interaction.)
void main() {
  testWidgets('LibraryScreen per-work menu carries a tooltip, matching '
      "the river row's twin", (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final profileId = await db.profilesDao.create('Ada');
    final profile = (await db.profilesDao.all()).single;
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'note',
        title: 'A Kept Work',
        persistence: 'work',
        firstSeenEpochDay: 100);
    await db.spineDao
        .insertSegments(workId, const [(idx: 0, kind: 'prose', text: 'Hi.')]);

    await tester.pumpWidget(MaterialApp(
      home:
          LibraryScreen(db: db, profile: profile, onSwitchProfile: () {}),
    ));
    await tester.pumpAndSettle();

    final menu = tester.widget<PopupMenuButton<String>>(
        find.byKey(Key('work-menu-$workId')));
    expect(menu.tooltip, isNotNull);
    expect(menu.tooltip, isNotEmpty);
  });

  testWidgets('FeedsScreen: the OPML menu and each feed row menu carry '
      'tooltips', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.profilesDao.create('Ada');
    final profile = (await db.profilesDao.all()).single;
    final fetcher = ScriptedFetcher((u, h) => textResponse(''));
    await db.feedsDao
        .insertFeed(profileId: profile.id, url: 'https://cast.test/feed');
    final feed = (await db.feedsDao.feedsOf(profile.id)).single;

    await tester.pumpWidget(MaterialApp(
      home: FeedsScreen(
        db: db,
        repository: FeedsRepository(db: db, fetcher: fetcher),
        profile: profile,
      ),
    ));
    await tester.pumpAndSettle();

    final opmlMenu = tester
        .widget<PopupMenuButton<String>>(find.byKey(const Key('opml-menu')));
    expect(opmlMenu.tooltip, isNotNull);
    expect(opmlMenu.tooltip, isNotEmpty);

    final feedMenu = tester.widget<PopupMenuButton<String>>(
        find.byKey(Key('feed-menu-${feed.id}')));
    expect(feedMenu.tooltip, isNotNull);
    expect(feedMenu.tooltip, isNotEmpty);
  });

  testWidgets("the mini bar's speed cycler carries a tooltip explaining "
      'what it does', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final profileId = await db.profilesDao.create('Ada');
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Tides and Their Clocks',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.example.test/ep1.mp3');
    final feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://cast.example.test/feed.xml');
    await db.feedsDao.insertEpisode(
        workId: workId,
        feedId: feedId,
        guid: 'ep1',
        enclosureUrl: 'https://cast.example.test/ep1.mp3',
        publishedAtMs: 0);
    final work = (await db.spineDao.worksOf(profileId)).single;
    final player = FakeEpisodePlayer();
    final controller = PlayerController(
        db: db, profileId: profileId, createPlayer: () => player);
    addTearDown(controller.dispose);
    await controller.playWork(work);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: MiniPlayerBar(controller: controller)),
    ));
    await tester.pump();

    final tooltip = tester.widget<Tooltip>(find.ancestor(
        of: find.byKey(const Key('player-speed')),
        matching: find.byType(Tooltip)));
    expect(tooltip.message, 'Playback speed');
  });
}
