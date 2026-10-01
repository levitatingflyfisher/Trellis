import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/episodes/episode_actions.dart';
import 'package:trellis/features/feeds/episode_download_coordinator.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/reader/reader_doors.dart';
import 'package:trellis/features/reader/reader_screen.dart';
import 'package:trellis/features/transcribe/transcribe_coordinator.dart';
import 'package:trellis/features/works/work_open.dart';
import 'package:trellis/features/works/work_page.dart';
import 'package:trellis/main.dart';
import 'package:trellis/services/device_services.dart';

import '../../support/fake_player.dart';
import '../../support/fake_services.dart';
import '../../support/pick_reader.dart';
import '../../support/scripted_fetcher.dart';
import '../../support/tabs.dart';

/// The work page (1.5.4): every row tap opens it, Play on a row never
/// does, and it opens on the mode last used.
void main() {
  late AppDatabase db;
  late int profileId;
  late int feedId;
  late int episode;
  late int article;
  final day = DateTime.now().millisecondsSinceEpoch;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://x.test/f', title: 'Night Sky');
    episode = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Aurora season',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://x.test/aurora.mp3');
    await db.feedsDao.insertEpisode(
        workId: episode,
        feedId: feedId,
        guid: 'aurora',
        enclosureUrl: 'https://x.test/aurora.mp3',
        durationMs: 60 * 60000,
        publishedAtMs: day - 1000);
    await db.feedsDao.fillNotes(episode,
        html: '<p>Chapters: 12:34 the comet. Map: '
            '<a href="https://maps.test/sky">sky map</a></p>',
        plain: 'Chapters: 12:34 the comet. Map: sky map');
    article = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'article',
        title: 'Field notes',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://x.test/field');
    await db.feedsDao.insertEpisode(
        workId: article,
        feedId: feedId,
        guid: 'field',
        publishedAtMs: day - 2000);
    await db.spineDao.insertSegments(
        article, const [(idx: 0, kind: 'prose', text: 'The marsh at dawn.')]);
  });
  tearDown(() => db.close());

  group('in the app', () {
    Future<FakeEpisodePlayer> pumpApp(WidgetTester tester) async {
      final player = FakeEpisodePlayer();
      await tester.pumpWidget(TrellisApp(
          db: db,
          fetcher: ScriptedFetcher((u, h) => textResponse('')),
          createPlayer: () => player));
      await tester.pumpAndSettle();
      await pickReader(tester, 'Ada');
      return player;
    }

    testWidgets('a row tap in Latest opens the work page', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.text('Aurora season'));
      await tester.pumpAndSettle();
      expect(find.byType(WorkPage), findsOneWidget);
      expect(find.byKey(const Key('mode-listen')), findsOneWidget);
      expect(find.byKey(const Key('mode-read')), findsOneWidget);
      expect(find.textContaining('the comet'), findsOneWidget);
    });

    testWidgets('Play on a row plays and stays on the list', (tester) async {
      final player = await pumpApp(tester);
      await tester.tap(find.byKey(Key('play-$episode')));
      await tester.pumpAndSettle();
      expect(find.byType(WorkPage), findsNothing);
      expect(player.loadedUrl, 'https://x.test/aurora.mp3');
    });
  });

  group('Remove belongs to the work', () {
    late int book;
    setUp(() async {
      book = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'book',
          title: 'Marsh book',
          persistence: 'work',
          firstSeenEpochDay: 100);
      await db.spineDao.insertSegments(
          book, const [(idx: 0, kind: 'prose', text: 'Reeds and herons.')]);
    });

    Future<void> pumpApp(WidgetTester tester) async {
      await tester.pumpWidget(TrellisApp(
          db: db,
          fetcher: ScriptedFetcher((u, h) => textResponse('')),
          createPlayer: () => FakeEpisodePlayer()));
      await tester.pumpAndSettle();
      await pickReader(tester, 'Ada');
    }

    /// Remove on the page: the page goes at once, and the lasting Undo
    /// stays on the screen that opened it.
    Future<void> removeFromPage(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('work-page-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('remove-$book')));
      await tester.pumpAndSettle();
      expect(find.byType(WorkPage), findsNothing, reason: 'the page goes');
      expect(find.text('Undo'), findsOneWidget);
      expect(await db.spineDao.workById(book), isNotNull,
          reason: 'it waits while Undo is on offer');
    }

    Future<void> letGo(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();
    }

    testWidgets('from the Library: Undo lasts, and letting go removes it',
        (tester) async {
      await pumpApp(tester);
      await toTab(tester, 'Library');
      await tester.tap(find.text('Marsh book'));
      await tester.pumpAndSettle();
      await removeFromPage(tester);
      expect(find.text('Marsh book'), findsNothing,
          reason: 'the Library hides it while Undo is on offer');
      await tester.pump(const Duration(hours: 1));
      expect(find.text('Undo'), findsOneWidget, reason: 'Undo never expires');
      await letGo(tester);
      expect(await db.spineDao.workById(book), isNull);
      expect(find.text('Marsh book'), findsNothing);
    });

    testWidgets('from Search', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.byKey(const Key('river-search')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('search-field')), 'marsh');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Marsh book'));
      await tester.pumpAndSettle();
      await removeFromPage(tester);
      await letGo(tester);
      expect(await db.spineDao.workById(book), isNull);
    });

    testWidgets('Undo on the opener keeps it', (tester) async {
      await pumpApp(tester);
      await toTab(tester, 'Library');
      await tester.tap(find.text('Marsh book'));
      await tester.pumpAndSettle();
      await removeFromPage(tester);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(await db.spineDao.workById(book), isNotNull);
      expect(find.text('Marsh book'), findsOneWidget);
      expect(find.text('Undo'), findsNothing);
    });
  });

  group('the page', () {
    late PlayerController controller;
    late FakeEpisodePlayer player;
    late Directory dir;
    final opened = <Uri>[];

    setUp(() {
      player = FakeEpisodePlayer();
      controller = PlayerController(
          db: db, profileId: profileId, createPlayer: () => player);
      dir = Directory.systemTemp.createTempSync('trellis-work-page');
      opened.clear();
    });
    tearDown(() {
      controller.dispose();
      dir.deleteSync(recursive: true);
    });

    late DeviceServices services;
    late EpisodeDownloadCoordinator downloader;

    Future<void> pumpPage(WidgetTester tester, int workId) async {
      services = testServices(dir);
      downloader = EpisodeDownloadCoordinator(services: services, db: db);
      final actions = EpisodeActions(
          db: db,
          profileId: profileId,
          player: controller,
          downloader: downloader,
          transcriber: TranscribeCoordinator(db: db, services: services),
          services: services,
          transcribeRate: () => 1 / 12);
      final doors = WorkDoors(
          db: db,
          profileId: profileId,
          readerDoors: ReaderDoors(player: controller),
          actions: actions,
          openLink: (u) async => opened.add(u),
          transcribeRate: () => 1 / 12);
      final work = (await db.spineDao.workById(workId))!;
      final ep = await db.feedsDao.episodeOf(workId);
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                  body: Center(
                      child: TextButton(
                          onPressed: () =>
                              doors.open(context, (work: work, episode: ep)),
                          child: const Text('open')))))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Finder selected(String mode) => find.descendant(
        of: find.byKey(const Key('mode-selected')),
        matching: find.byKey(Key('mode-$mode')));

    testWidgets('an untouched episode opens on Listen, a text on Read',
        (tester) async {
      await pumpPage(tester, episode);
      expect(selected('listen'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await pumpPage(tester, article);
      expect(selected('read'), findsOneWidget);
    });

    Future<void> touch({required int readAt, required int heardAt}) async {
      await db.feedsDao
          .savePlayerPosition(profileId: profileId, workId: episode, tMs: 5000);
      await db.spineDao.savePosition(
          profileId: profileId,
          workId: episode,
          segmentIdx: 0,
          wordIdx: 0,
          lastModality: 'read');
      await db.customStatement(
          'UPDATE positions SET updated_at_ms = $readAt WHERE work_id = $episode');
      await db.customStatement('UPDATE player_positions SET updated_at_ms = '
          '$heardAt WHERE work_id = $episode');
    }

    testWidgets('it opens on Read when reading came after listening',
        (tester) async {
      await touch(readAt: 2000, heardAt: 1000);
      await pumpPage(tester, episode);
      expect(selected('read'), findsOneWidget);
    });

    testWidgets('it opens on Listen when listening came after reading',
        (tester) async {
      await touch(readAt: 1000, heardAt: 2000);
      await pumpPage(tester, episode);
      expect(selected('listen'), findsOneWidget);
    });

    testWidgets('speaking a text is listening to it', (tester) async {
      await db.spineDao.savePosition(
          profileId: profileId,
          workId: article,
          segmentIdx: 0,
          wordIdx: 0,
          lastModality: 'speak');
      await pumpPage(tester, article);
      expect(selected('listen'), findsOneWidget);
    });

    testWidgets('Read on an untranscribed episode shows the notes and the '
        'Transcribe offer with its estimate', (tester) async {
      await pumpPage(tester, episode);
      await tester.tap(find.byKey(const Key('mode-read')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notes-screen')), findsOneWidget);
      expect(find.byKey(const Key('transcribe-offer')), findsOneWidget);
      expect(find.textContaining('the comet'), findsOneWidget);
      expect(find.text('Transcribe (about 5 min)'), findsOneWidget);
    });

    testWidgets('tapping Transcribe says so at once, with its estimate, and '
        'shows the job on the page', (tester) async {
      await pumpPage(tester, episode);
      await tester.tap(find.byKey(const Key('mode-read')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('transcribe-now')));
      await tester.pumpAndSettle();
      if (find.byKey(const Key('consent-accept')).evaluate().isNotEmpty) {
        await tester.tap(find.byKey(const Key('consent-accept')));
      }
      await tester.pump();
      await tester.pump();
      expect(find.text('Transcribing… about 5 min'), findsOneWidget);
      expect(find.text('See progress'), findsOneWidget);
      // The page under the notes shows the job while it runs (the fake
      // engine here finishes within a few frames).
      expect(
          find.byKey(Key('page-transcribe-progress-$episode'),
              skipOffstage: false),
          findsOneWidget);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });

    testWidgets('a timestamp in the notes plays from there', (tester) async {
      await pumpPage(tester, episode);
      await tester.tapOnText(find.textRange.ofSubstring('12:34'));
      await tester.pumpAndSettle();
      expect(controller.current?.id, episode);
      expect(
          player.log.contains('seek:754000') ||
              player.loadedInitialPosition ==
                  const Duration(minutes: 12, seconds: 34),
          isTrue,
          reason: player.log.join(', '));
    });

    testWidgets('a link in the notes asks before it opens', (tester) async {
      await pumpPage(tester, episode);
      await tester.tapOnText(find.textRange.ofSubstring('sky map'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('link-confirm')), findsOneWidget);
      expect(find.text('maps.test'), findsOneWidget);
      expect(opened, isEmpty);
      await tester.tap(find.byKey(const Key('link-open')));
      await tester.pumpAndSettle();
      expect(opened, [Uri.parse('https://maps.test/sky')]);
    });

    testWidgets('the ⋮ is the shared menu, and Keep is a visible action',
        (tester) async {
      await pumpPage(tester, episode);
      expect(find.byKey(Key('page-keep-$episode')), findsOneWidget);
      await tester.tap(find.byKey(const Key('work-page-menu')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('share-$episode')), findsOneWidget);
      expect(find.byKey(Key('mark-played-$episode')), findsOneWidget);
      // Transcribe is a visible action until there is a transcript.
      expect(find.byKey(Key('transcribe-$episode')), findsNothing);
      expect(find.byKey(Key('page-transcribe-$episode')), findsOneWidget);
    });

    testWidgets('a picked translation is remembered for next time',
        (tester) async {
      await db.spineDao.upsertTranslationSentence(
          workId: article,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: 'es',
          sourceText: 'The marsh at dawn.',
          body: 'El pantano al alba.');
      await pumpPage(tester, article);
      expect(find.text('Original · Unknown'), findsOneWidget);
      await tester.tap(find.byKey(const Key('lang-es')));
      await tester.pumpAndSettle();
      expect((await db.spineDao.workById(article))!.readLang, 'es');
      expect(await db.spineDao.activeTranslationLang(article), 'es');
    });

    testWidgets('picking a translation opens Read in it', (tester) async {
      await db.spineDao.upsertTranslationSentence(
          workId: article,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: 'es',
          sourceText: 'The marsh at dawn.',
          body: 'El pantano al alba.');
      await db.spineDao.setShowTranslationLayer(article, false);
      await pumpPage(tester, article);
      await tester.tap(find.byKey(const Key('lang-es')));
      await tester.pumpAndSettle();

      expect(find.byType(ReaderScreen), findsOneWidget);
      expect(await db.spineDao.showTranslationLayer(article), isTrue,
          reason: 'the reader shows the picked translation even if its '
              'display was turned off before');
    });

    testWidgets('picking the original opens nothing', (tester) async {
      await pumpPage(tester, article);
      await tester.tap(find.byKey(const Key('lang-original')));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsNothing);
    });

    Future<void> transcribeEpisode() async {
      await db.spineDao.insertSegments(
          episode, const [(idx: 0, kind: 'prose', text: 'Lights overhead.')]);
      await db.spineDao.insertAlignments(
          episode, const [(segmentIdx: 0, tStartMs: 0, tEndMs: 900)]);
    }

    Future<void> reopen(WidgetTester tester) async {
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('Listen, then Read the transcript: the page reopens on Read',
        (tester) async {
      await transcribeEpisode();
      await pumpPage(tester, episode);
      await tester.tap(find.byKey(const Key('mode-listen')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('mode-read')));
      await tester.pumpAndSettle();
      await tester.pageBack(); // the transcript
      await tester.pumpAndSettle();
      await reopen(tester);
      expect(selected('read'), findsOneWidget);
    });

    testWidgets('Read on the notes screen is remembered too', (tester) async {
      await pumpPage(tester, episode);
      await tester.tap(find.byKey(const Key('mode-read')));
      await tester.pumpAndSettle();
      await tester.pageBack(); // the notes screen
      await tester.pumpAndSettle();
      await reopen(tester);
      expect(selected('read'), findsOneWidget);
    });

    Future<List<String?>> pageMenuValues(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('work-page-menu')));
      await tester.pumpAndSettle();
      final values = [
        for (final e in tester.widgetList<PopupMenuItem<String>>(
            find.byWidgetPredicate((w) => w is PopupMenuItem<String>)))
          e.value,
      ];
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
      return values;
    }

    testWidgets('the ⋮ holds nothing that is already a button', (tester) async {
      await pumpPage(tester, episode);
      expect(find.byKey(Key('page-play-next-$episode')), findsOneWidget);
      expect(find.byKey(const Key('lang-translate')), findsOneWidget);
      final values = await pageMenuValues(tester);
      expect(values, isNotEmpty);
      for (final shown in ['play-next', 'play-last', 'download', 'transcribe',
          'translate', 'keep']) {
        expect(values, isNot(contains(shown)), reason: shown);
      }
      expect(values, containsAll(['share', 'mark-played']));
    });

    // 1.5.6: an untranscribed English episode offered translating into
    // English. Translating needs text, and never into the source.
    testWidgets('without a transcript Translate waits for one, and nothing '
        'promises English', (tester) async {
      await pumpPage(tester, episode);
      final translate =
          tester.widget<ButtonStyleButton>(find.byKey(const Key('lang-translate')));
      expect(translate.onPressed, isNull);
      expect(find.textContaining('into English'), findsNothing);
      expect(find.text('Translating needs a transcript first.'),
          findsOneWidget);
      expect(await pageMenuValues(tester), isNot(contains('translate')));
    });

    testWidgets('an English episode is never offered translation into '
        'English', (tester) async {
      await db.spineDao.setWorkLang(episode, 'en');
      await pumpPage(tester, episode);
      expect(await pageMenuValues(tester), isNot(contains('translate')));
      await transcribeEpisode();
      await tester.pumpAndSettle();
      expect(await pageMenuValues(tester), isNot(contains('translate')));
    });

    // 1.5.6: the page went stale after a job — Read worked only after
    // leaving and coming back, and Download stayed after it finished.
    testWidgets('Transcribe is a visible action until the transcript lands, '
        'and then Read opens it without reopening the page', (tester) async {
      await pumpPage(tester, episode);
      expect(find.byKey(Key('page-transcribe-$episode')), findsOneWidget);
      expect(find.text('No transcript yet: Read opens the show notes.'),
          findsOneWidget);
      await transcribeEpisode();
      await tester.pumpAndSettle();
      expect(find.byKey(Key('page-transcribe-$episode')), findsNothing);
      expect(find.text('No transcript yet: Read opens the show notes.'),
          findsNothing);
      await tester.tap(find.byKey(const Key('mode-read')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notes-screen')), findsNothing);
    });

    testWidgets('Download leaves the page when the download finishes',
        (tester) async {
      await pumpPage(tester, episode);
      expect(find.byKey(Key('page-download-$episode')), findsOneWidget);
      final file =
          services.audioFileFor(episode, 'https://x.test/aurora.mp3');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync([1, 2, 3]);
      downloader.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byKey(Key('page-download-$episode')), findsNothing);
    });

    testWidgets('audio a transcription fetched clears Download too',
        (tester) async {
      await pumpPage(tester, episode);
      expect(find.byKey(Key('page-download-$episode')), findsOneWidget);
      // The transcription's own fetch: the file lands, the downloader is
      // never told, then the transcript is written.
      final file =
          services.audioFileFor(episode, 'https://x.test/aurora.mp3');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync([1, 2, 3]);
      await transcribeEpisode();
      await tester.pumpAndSettle();
      expect(find.byKey(Key('page-download-$episode')), findsNothing);
    });

    testWidgets('a transcribed episode keeps Transcribe + translate in its ⋮',
        (tester) async {
      await transcribeEpisode();
      await pumpPage(tester, episode);
      final values = await pageMenuValues(tester);
      expect(values, contains('translate'),
          reason: 'its Translate… opens the reader picker, a different act');
    });

    testWidgets('a transcribed episode offers Transcribe again', (tester) async {
      await transcribeEpisode();
      await pumpPage(tester, episode);
      await tester.tap(find.byKey(const Key('work-page-menu')));
      await tester.pumpAndSettle();
      expect(find.text('Transcribe again'), findsOneWidget);
    });

    testWidgets('a picked language is selected when the page reopens',
        (tester) async {
      await db.spineDao.upsertTranslationSentence(
          workId: article,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: 'es',
          sourceText: 'The marsh at dawn.',
          body: 'El pantano al alba.');
      await pumpPage(tester, article);
      await tester.tap(find.byKey(const Key('lang-es')));
      await tester.pumpAndSettle();
      await tester.pageBack(); // the reader the pick opened
      await tester.pumpAndSettle();
      await reopen(tester);
      expect(
          find.descendant(
              of: find.byKey(const Key('lang-es')),
              matching: find.byIcon(Icons.check)),
          findsOneWidget);
    });

    testWidgets('a kept episode is un-kept, never deleted, from its page',
        (tester) async {
      await db.spineDao.promoteWork(episode);
      await pumpPage(tester, episode);
      await tester.tap(find.byKey(const Key('work-page-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('remove-from-library-$episode')));
      await tester.pumpAndSettle();
      expect(find.byType(WorkPage), findsNothing);
      expect((await db.spineDao.workById(episode))!.persistence, 'work',
          reason: 'nothing changes while Undo is on offer');
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();
      final work = await db.spineDao.workById(episode);
      expect(work, isNotNull);
      expect(work!.persistence, 'ephemeron');
      expect(await db.feedsDao.episodeOf(episode), isNotNull);
    });
  });

  group('pure rules', () {
    test('transcribeEstimate is honest when it does not know', () {
      expect(transcribeEstimate(60 * 60000, 1 / 12), 'about 5 min');
      expect(transcribeEstimate(null, 1 / 12), 'time unknown');
      expect(transcribeEstimate(60 * 60000, null), 'time unknown');
    });

    test('languageNameOf reads region tags and says Unknown for none', () {
      expect(languageNameOf('en-us'), 'English');
      expect(languageNameOf(null), 'Unknown');
    });
  });
}
