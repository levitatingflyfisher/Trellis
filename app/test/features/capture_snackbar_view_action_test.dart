import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/captures_screen.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/fake_services.dart';
import '../support/scripted_fetcher.dart';
import 'dart:io';

/// Campaign 9 Phase 1 — user: "two bookmark symbols… unclear which is doing
/// what". The capture snackbar was a dead end: "Captured." with nowhere to
/// go, so a first-time user had no discovery path to where captures land.
/// This is the first-discovery test: capture, then follow the snackbar's
/// new "View" action straight to CapturesScreen.
void main() {
  testWidgets('the capture snackbar\'s View action opens CapturesScreen',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final profileId = await db.profilesDao.create('Ada');
    final feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://cast.example.test/feed.xml');
    final today = DateTime.now().toUtc().millisecondsSinceEpoch ~/
        Duration.millisecondsPerDay;
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Tides and Their Clocks',
        persistence: 'ephemeron',
        firstSeenEpochDay: today,
        sourceUrl: 'https://cast.example.test/ep1.mp3');
    await db.feedsDao.insertEpisode(
        workId: workId,
        feedId: feedId,
        guid: 'ep1',
        enclosureUrl: 'https://cast.example.test/ep1.mp3',
        publishedAtMs: 0);

    final player = FakeEpisodePlayer();
    final dir = Directory.systemTemp.createTempSync('trellis-capture-view');
    addTearDown(() => dir.deleteSync(recursive: true));

    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((u, h) => textResponse('')),
        createPlayer: () => player,
        services: testServices(dir)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('River'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('play-$workId')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('player-capture')), findsOneWidget);
    await tester.tap(find.byKey(const Key('player-capture')));
    await tester.pump();
    // Let the SnackBar's entrance transition settle before hit-testing its
    // action — mid-slide-in coordinates don't match final layout.
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Captured.'), findsOneWidget);
    expect(find.text('View'), findsOneWidget,
        reason: 'the snackbar must offer a way to the captures list — '
            'the first discovery path for where captures go');

    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();

    expect(find.byType(CapturesScreen), findsOneWidget);
  });
}
