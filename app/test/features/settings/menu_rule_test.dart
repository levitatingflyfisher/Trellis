import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhearth_design/openhearth_design.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/main.dart';

import '../../support/fake_player.dart';
import '../../support/fake_services.dart';
import '../../support/pick_reader.dart';
import '../../support/scripted_fetcher.dart';
import '../../support/tabs.dart';

/// The ⋮ rule (board-0131, owner: "I still am annoyed by the three dots
/// hiding different things on different screens"):
///
///  * app-wide things live in Settings, on the bottom bar, and in no ⋮;
///  * a top bar's ⋮ holds only that screen's own actions: Select first
///    where the screen lists things, then the screen's own rare actions;
///    the reader, which hides the bottom bar, ends its ⋮ with Reading
///    settings;
///  * a screen with none of its own has no ⋮ at all.
void main() {
  late Directory dir;
  late AppDatabase db;
  late FakeEpisodePlayer player;
  late int episodeId;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('trellis-menu-rule');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    player = FakeEpisodePlayer();
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> seed() async {
    final profileId = await db.profilesDao.create('Ada');
    final feedId = await db.feedsDao
        .insertFeed(profileId: profileId, url: 'https://cast.test/feed');
    await db.feedsDao.updateRefreshState(feedId,
        title: 'Night Sky', etag: null, lastModified: null, breakerJson: '{}');
    episodeId = await db.spineDao.insertWork(
      profileId: profileId,
      kind: 'episode',
      title: 'Aurora season',
      persistence: 'ephemeron',
      firstSeenEpochDay: DateTime.now().toUtc().millisecondsSinceEpoch ~/
          Duration.millisecondsPerDay,
      sourceUrl: 'https://cast.test/1.mp3',
    );
    await db.spineDao.insertSegments(
        episodeId, [(idx: 0, kind: 'prose', text: 'Show notes.')]);
    await db.feedsDao.insertEpisode(
      workId: episodeId,
      feedId: feedId,
      guid: 'guid-1',
      enclosureUrl: 'https://cast.test/1.mp3',
      publishedAtMs: 1000,
    );
    final textId = await db.spineDao.insertWork(
      profileId: profileId,
      kind: 'text',
      title: 'A quiet text',
      persistence: 'kept',
      firstSeenEpochDay: 1,
    );
    await db.spineDao
        .insertSegments(textId, [(idx: 0, kind: 'prose', text: 'Hello.')]);
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await seed();
    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((u, h) => textResponse('')),
        createPlayer: () => player,
        services: testServices(dir)));
    await tester.pumpAndSettle();
    await pickReader(tester, 'Ada');
  }

  /// The words of an open menu's items, in order, then closes it.
  Future<List<String>> menu(WidgetTester tester, Finder button) async {
    await tester.tap(button);
    await tester.pumpAndSettle();
    final words = [
      for (final e
          in find.byWidgetPredicate((w) => w is PopupMenuItem).evaluate())
        [
          for (final t in find
              .descendant(
                  of: find.byWidget(e.widget), matching: find.byType(Text))
              .evaluate())
            (t.widget as Text).data ?? '',
        ].join(' '),
    ];
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    return words;
  }

  /// The ⋮ in the top bar in view, if there is one.
  Finder topMenu() => find.descendant(
      of: find.byType(AppBar),
      matching: find.byWidgetPredicate((w) => w is OhBarOverflow));

  void expectNoAppWideItem(List<String> words, String where) {
    for (final w in words) {
      for (final item in _appWide) {
        expect(w.startsWith(item), isFalse,
            reason: '“$w” is app-wide, and in the ⋮ of $where');
      }
    }
  }

  testWidgets('the tabs’ ⋮: Latest holds Select, and Queue, Library, '
      'Courses and Settings have none', (tester) async {
    await pumpApp(tester);
    final latest = await menu(tester, find.byKey(const Key('river-more')));
    expect(latest, ['Select']);
    for (final tab in ['Queue', 'Library', 'Courses', 'Settings']) {
      await toTab(tester, tab);
      expect(topMenu(), findsNothing, reason: tab);
    }
  });

  testWidgets('pages under the tabs: Subscriptions holds its OPML items, a '
      'show’s page and History hold Select', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('manage-feeds')));
    await tester.pumpAndSettle();
    final subscriptions = await menu(tester, topMenu());
    expect(subscriptions, ['Import OPML', 'Export OPML']);

    await tester.tap(find.text('Night Sky'));
    await tester.pumpAndSettle();
    expect(await menu(tester, topMenu()), ['Select']);

    await toTab(tester, 'Queue');
    await tester.tap(find.byKey(const Key('queue-history')));
    await tester.pumpAndSettle();
    expect(await menu(tester, topMenu()), ['Select']);
  });

  testWidgets('an episode’s page holds only that episode’s items',
      (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Aurora season'));
    await tester.pumpAndSettle();
    expectNoAppWideItem(await menu(tester, topMenu()), 'the episode page');
  });

  testWidgets('the reader holds this text’s items, then Reading settings, '
      'last', (tester) async {
    await pumpApp(tester);
    await toTab(tester, 'Library');
    await tester.tap(find.text('A quiet text'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mode-read')));
    await tester.pumpAndSettle();

    final reader =
        await menu(tester, find.byKey(const Key('reader-overflow')));
    expect(reader, [
      'Word ledger',
      'Distill into a course',
      'Language: not set',
      'Read aloud voices',
      'Translate…',
      'Reading settings',
    ]);
    expectNoAppWideItem(reader.take(reader.length - 1).toList(), 'the reader');
  });

  testWidgets('the player bar’s ⋮ holds the player’s own items, and no '
      'setting', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(Key('play-$episodeId')));
    await tester.pumpAndSettle();
    final bar = await menu(tester, find.byKey(const Key('player-menu')));
    expect(bar, [
      'Go to show',
      'Capture this moment',
      'Captures',
      'Queue',
      'Forward 30 seconds',
      'Sleep timer',
    ]);
  });

  testWidgets('every list’s row ⋮ starts with the same shared items, in '
      'the same order, then the list’s own', (tester) async {
    await pumpApp(tester);
    await db.queueDao.playLast(
        profileId: (await db.profilesDao.all()).single.id,
        workId: episodeId,
        nowMs: 1);
    const shared = [
      'Play next',
      'Play last',
      // Stream or download, said plainly (owner, 23 Oct).
      'Stream now',
      'Download, then play',
      'Download',
      'Mark played',
      'Transcribe',
      'Share',
    ];
    final row = find.byKey(Key('menu-$episodeId'));
    final latest = await menu(tester, row);
    expect(latest.take(shared.length), shared);
    expect(latest.skip(shared.length), ['Keep', 'Let it pass']);

    await toTab(tester, 'Queue');
    final queue = await menu(tester, row);
    expect(queue.take(shared.length), shared);
    expect(queue.skip(shared.length), ['Remove from Queue']);
  });
}

/// Every app-wide item before the rule: none may sit in a ⋮.
const _appWide = [
  'Theme',
  'Follow phone',
  'Light',
  'Dark',
  'Learning language',
  'Models & storage',
  'Backup & migrate',
  'Switch reader',
  'Thinking (AI helper)',
  'What you’ve built',
  'FSRS',
  'Trim silence',
  'Headphone buttons',
  'Reading style',
  'Use the system voice',
  'Read citations aloud',
];
