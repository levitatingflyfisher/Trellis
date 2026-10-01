import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/episodes/episode_actions.dart';
import 'package:trellis/features/feeds/episode_download_coordinator.dart';
import 'package:trellis/features/models/models_screen.dart';
import 'package:trellis/features/storage/storage_by_item_screen.dart';
import 'package:trellis/services/device_services.dart';

import '../support/fake_services.dart';

/// 1.5.8 "Storage by item": every work holding files or text, with what
/// each part costs and one delete per part.
void main() {
  late Directory dir;
  late AppDatabase db;
  late DeviceServices services;
  late EpisodeActions actions;
  late EpisodeDownloadCoordinator downloader;
  late int profile;
  late int episode;
  const url = 'https://x.test/aurora.mp3';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('trellis-by-item');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    services = testServices(dir);
    actions = EpisodeActions(
        db: db,
        profileId: 0,
        downloader: downloader =
            EpisodeDownloadCoordinator(services: services, db: db),
        services: services);
    profile = await db.profilesDao.create('Ada');
    final feed = await db.feedsDao
        .insertFeed(profileId: profile, url: 'https://x.test/f', title: 'Sky');
    episode = await db.spineDao.insertWork(
        profileId: profile,
        kind: 'episode',
        title: 'Aurora season',
        persistence: 'work',
        firstSeenEpochDay: 1);
    await db.feedsDao.insertEpisode(
        workId: episode,
        feedId: feed,
        guid: 'a',
        enclosureUrl: url,
        publishedAtMs: 1);
    await db.spineDao.insertSegments(
        episode, const [(idx: 0, kind: 'prose', text: 'Lights overhead.')]);
    await db.spineDao.insertAlignments(
        episode, const [(segmentIdx: 0, tStartMs: 0, tEndMs: 900)]);
    await db.spineDao.upsertTranslationSentence(
        workId: episode,
        segmentIdx: 0,
        sentenceIdx: 0,
        lang: 'es',
        sourceText: 'Lights overhead.',
        body: 'Luces arriba.');
    services.audioFileFor(episode, url)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(List.filled(5000, 1));
  });
  tearDown(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        home: StorageByItemScreen(
            db: db,
            services: services,
            profileId: profile,
            actions: actions)));
    await tester.pumpAndSettle();
  }

  Finder part(String name, int id) => find.byKey(Key('stored-$name-$id'));

  Future<void> delete(WidgetTester tester, String name, int id) async {
    await tester.tap(find.byKey(Key('stored-delete-$name-$id')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget, reason: 'asks once');
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton))
        .last);
    await tester.pumpAndSettle();
  }

  testWidgets('a work lists its audio, transcript and each translation',
      (tester) async {
    await pump(tester);
    expect(find.text('Aurora season'), findsOneWidget);
    expect(find.descendant(
            of: part('audio', episode), matching: find.text('5.0 kB')),
        findsOneWidget);
    expect(part('transcript', episode), findsOneWidget);
    expect(find.descendant(
            of: part('translation-es', episode),
            matching: find.text('Spanish translation')),
        findsOneWidget);
    expect(
        find.descendant(
            of: part('transcript', episode),
            matching: find.textContaining('about')),
        findsOneWidget,
        reason: 'text in the database is measured, not freed at once');
  });

  testWidgets('the transcript asks once, then it and its translations go',
      (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(Key('stored-delete-transcript-$episode')));
    await tester.pumpAndSettle();
    expect(find.textContaining('You can transcribe again'), findsOneWidget);
    expect(find.textContaining('its translations'), findsOneWidget);
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('Keep')));
    await tester.pumpAndSettle();
    expect(part('transcript', episode), findsOneWidget, reason: 'kept');

    await delete(tester, 'transcript', episode);
    expect(part('transcript', episode), findsNothing);
    expect(part('translation-es', episode), findsNothing);
    expect(part('audio', episode), findsOneWidget);
    expect(await db.spineDao.alignmentsOf(episode), isEmpty);
  });

  testWidgets('removing the download deletes the file', (tester) async {
    await pump(tester);
    final revision = downloader.revision;
    await delete(tester, 'audio', episode);
    expect(services.audioFileFor(episode, url).existsSync(), isFalse);
    expect(downloader.revision, greaterThan(revision),
        reason: 'other lists offer Download again');
    expect(part('audio', episode), findsNothing);
    expect(find.text('Aurora season'), findsOneWidget,
        reason: 'its transcript is still stored');
  });

  testWidgets('audio left by a removed work is listed and can go',
      (tester) async {
    final orphan = services.audioFileFor(999, 'https://x.test/old.mp3')
      ..writeAsBytesSync(List.filled(3000, 1));
    await pump(tester);
    expect(find.text('Removed item'), findsOneWidget);
    await delete(tester, 'audio', 999);
    expect(orphan.existsSync(), isFalse);
    expect(find.text('Removed item'), findsNothing);
  });

  testWidgets('a file fetched under an older enclosure URL still goes',
      (tester) async {
    services.audioFileFor(episode, url).deleteSync();
    final old = services.audioFileFor(episode, 'https://x.test/aurora.m4a')
      ..writeAsBytesSync(List.filled(2000, 1));
    await pump(tester);
    await delete(tester, 'audio', episode);
    expect(old.existsSync(), isFalse);
    expect(part('audio', episode), findsNothing);
  });

  testWidgets('another reader\'s works are not listed', (tester) async {
    final other = await db.profilesDao.create('Bo');
    final theirs = await db.spineDao.insertWork(
        profileId: other,
        kind: 'article',
        title: 'Bo\'s diary',
        persistence: 'work',
        firstSeenEpochDay: 1);
    await db.spineDao.insertSegments(
        theirs, const [(idx: 0, kind: 'prose', text: 'Hello.')]);
    await db.spineDao.upsertTranslationSentence(
        workId: theirs,
        segmentIdx: 0,
        sentenceIdx: 0,
        lang: 'fr',
        sourceText: 'Hello.',
        body: 'Bonjour.');
    await pump(tester);
    expect(find.text('Aurora season'), findsOneWidget);
    expect(find.text('Bo\'s diary'), findsNothing);
  });

  testWidgets('a partial download is not a stored item', (tester) async {
    File('${services.audioFileFor(5, url).path}.part')
        .writeAsBytesSync(List.filled(100, 1));
    await pump(tester);
    expect(part('audio', 5), findsNothing);
  });

  testWidgets('survives 320 dp at twice the text size', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
            data: const MediaQueryData(
                size: Size(320, 900), textScaler: TextScaler.linear(2)),
            child: StorageByItemScreen(
                db: db,
                services: services,
                profileId: profile,
                actions: actions))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(Key('stored-delete-audio-$episode')), findsOneWidget);
  });

  testWidgets('Models & storage opens it', (tester) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final store = FakeModelStore();
    await tester.pumpWidget(MaterialApp(
        home: ModelsScreen(
            store: store,
            registry: ModelRegistry.starter(),
            services: services,
            db: db,
            profileId: profile,
            actions: actions)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('storage-by-item')));
    await tester.pumpAndSettle();
    expect(find.byType(StorageByItemScreen), findsOneWidget);
    expect(find.text('Aurora season'), findsOneWidget);
  });
}
