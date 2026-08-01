import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/intake/gutenberg_screen.dart';
import 'package:trellis/features/intake/url_intake.dart';
import 'package:trellis/features/models/models_screen.dart';
import 'package:trellis/main.dart';
import 'package:trellis/services/device_services.dart' show WebFetchLane;

import '../support/fake_player.dart';
import '../support/fake_services.dart';
import '../support/scripted_fetcher.dart';

/// The web-tier honesty gates (proposal-2 §1): the PWA reads, studies,
/// listens and backs up — local ML rides the installed app. Where that is
/// true, the UI must not offer what must fail: no transcribe ITEMS in a
/// river episode's menu (the menu itself stays — Play next/Play last are
/// plain database writes, not an ML feature, and work on every tier), and
/// the models door opens a calm explanation instead of a screen whose file
/// operations throw under dart2js.
void main() {
  late AppDatabase db;
  late Directory tmp;
  late FakeEpisodePlayer player;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('trellis-webgate');
    player = FakeEpisodePlayer();
  });
  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<({int profileId, int workId})> seedEpisode() async {
    final profileId = await db.profilesDao.create('Ada');
    final feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://cast.example.test/feed.xml');
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Um episódio',
        persistence: 'ephemeron',
        firstSeenEpochDay: DateTime.now().toUtc().millisecondsSinceEpoch ~/
            Duration.millisecondsPerDay,
        sourceUrl: 'https://cast.example.test/ep1.mp3');
    await db.feedsDao.insertEpisode(
        workId: workId,
        feedId: feedId,
        guid: 'ep1',
        enclosureUrl: 'https://cast.example.test/ep1.mp3',
        publishedAtMs: DateTime.utc(2026, 8, 1).millisecondsSinceEpoch);
    return (profileId: profileId, workId: workId);
  }

  Future<void> pumpApp(WidgetTester tester,
      {required bool localMlAvailable}) async {
    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((u, h) => textResponse('')),
        createPlayer: () => player,
        services: testServices(tmp, localMlAvailable: localMlAvailable)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'the web tier offers play and the queue verbs, but no transcribe '
      'menu items', (t) async {
    final ids = await seedEpisode();
    await pumpApp(t, localMlAvailable: false);
    await t.tap(find.text('River'));
    await t.pumpAndSettle();

    expect(find.byKey(Key('play-${ids.workId}')), findsOneWidget);
    // The menu itself still shows — Play next/Play last are plain database
    // writes, not an ML feature — but nothing inside it can fail on this
    // tier.
    await t.tap(find.byKey(Key('menu-${ids.workId}')));
    await t.pumpAndSettle();
    expect(find.byKey(Key('play-next-${ids.workId}')), findsOneWidget);
    expect(find.byKey(Key('play-last-${ids.workId}')), findsOneWidget);
    expect(find.byKey(Key('transcribe-${ids.workId}')), findsNothing);
    expect(find.byKey(Key('translate-${ids.workId}')), findsNothing);
  });

  testWidgets('the native tier still offers the transcribe menu items',
      (t) async {
    final ids = await seedEpisode();
    await pumpApp(t, localMlAvailable: true);
    await t.tap(find.text('River'));
    await t.pumpAndSettle();

    await t.tap(find.byKey(Key('menu-${ids.workId}')));
    await t.pumpAndSettle();
    expect(find.byKey(Key('transcribe-${ids.workId}')), findsOneWidget);
  });

  testWidgets('the models door explains itself instead of throwing',
      (t) async {
    await seedEpisode();
    await pumpApp(t, localMlAvailable: false);
    await t.tap(find.byKey(const Key('open-models')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('web-tier-notice')), findsOneWidget);
    expect(find.byType(ModelsScreen), findsNothing);
    // Calm and honest: names what this tier does, not what it lacks in red.
    expect(find.textContaining('installed app'), findsWidgets);
  });

  testWidgets('the native tier models door still opens the manager',
      (t) async {
    await seedEpisode();
    await pumpApp(t, localMlAvailable: true);
    await t.tap(find.byKey(const Key('open-models')));
    await t.pumpAndSettle();

    expect(find.byType(ModelsScreen), findsOneWidget);
  });

  // Fetch honesty (the ML gate's sibling): in the browser most sites refuse
  // cross-site reads, so the two fetching doors must set expectations
  // upfront on the web tier — and stay quiet on the tier where fetching
  // just works.
  testWidgets('the web tier URL-intake door says most fetches will fail',
      (t) async {
    final profileId = await db.profilesDao.create('Ada');
    await t.pumpWidget(MaterialApp(
        home: UrlIntakeScreen(
            db: db,
            profileId: profileId,
            fetcher: ScriptedFetcher((u, h) => textResponse('')),
            webTier: true)));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('url-intake-web-note')), findsOneWidget);
    expect(find.textContaining('installed app'), findsOneWidget);
  });

  testWidgets('the native URL-intake door carries no browser caveat',
      (t) async {
    final profileId = await db.profilesDao.create('Ada');
    await t.pumpWidget(MaterialApp(
        home: UrlIntakeScreen(
            db: db,
            profileId: profileId,
            fetcher: ScriptedFetcher((u, h) => textResponse('')))));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('url-intake-web-note')), findsNothing);
  });

  testWidgets('the web tier Gutenberg door names the import fallback',
      (t) async {
    final profileId = await db.profilesDao.create('Ada');
    await t.pumpWidget(MaterialApp(
        home: GutenbergSearchScreen(
            db: db,
            profileId: profileId,
            fetcher: ScriptedFetcher((u, h) => textResponse('')),
            webTier: true)));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('gutenberg-web-note')), findsOneWidget);
    expect(find.textContaining('Import an EPUB'), findsOneWidget);
  });

  testWidgets('the native Gutenberg door carries no browser caveat',
      (t) async {
    final profileId = await db.profilesDao.create('Ada');
    await t.pumpWidget(MaterialApp(
        home: GutenbergSearchScreen(
            db: db,
            profileId: profileId,
            fetcher: ScriptedFetcher((u, h) => textResponse('')))));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('gutenberg-web-note')), findsNothing);
  });

  // The Skein lane: once a household daemon answers
  // same-origin, the CORS warning would be a lie — the doors must swap it
  // for a quiet, accurate line instead of just staying silent.
  testWidgets(
      'the skein-lane URL-intake door shows the quiet Skein note, never '
      'the CORS warning (which would be false now)', (t) async {
    final profileId = await db.profilesDao.create('Ada');
    await t.pumpWidget(MaterialApp(
        home: UrlIntakeScreen(
            db: db,
            profileId: profileId,
            fetcher: ScriptedFetcher((u, h) => textResponse('')),
            webTier: true,
            lane: WebFetchLane.skein)));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('url-intake-skein-note')), findsOneWidget);
    expect(find.byKey(const Key('url-intake-web-note')), findsNothing);
    expect(find.text('Fetching through your Skein on this computer.'),
        findsOneWidget);
  });

  testWidgets(
      'the skein-lane Gutenberg door shows the quiet Skein note, never '
      'the browser-refusal caveat (which would be false now)', (t) async {
    final profileId = await db.profilesDao.create('Ada');
    await t.pumpWidget(MaterialApp(
        home: GutenbergSearchScreen(
            db: db,
            profileId: profileId,
            fetcher: ScriptedFetcher((u, h) => textResponse('')),
            webTier: true,
            lane: WebFetchLane.skein)));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('gutenberg-skein-note')), findsOneWidget);
    expect(find.byKey(const Key('gutenberg-web-note')), findsNothing);
    expect(find.text('Fetching through your Skein on this computer.'),
        findsOneWidget);
  });
}
