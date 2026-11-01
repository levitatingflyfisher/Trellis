import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/episodes/episode_actions.dart';
import 'package:trellis/features/listen/listen_chain.dart';
import 'package:trellis/features/listen/spoken_episode.dart' show VoiceKind;
import 'package:trellis/features/listen/listen_jobs.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/reader/reader_doors.dart';
import 'package:trellis/features/reader/reader_screen.dart';
import 'package:trellis/features/reader/speech/speech_engine.dart';
import 'package:trellis/features/works/work_open.dart';

import '../../support/fake_player.dart';
import '../../support/fake_services.dart';

/// The learning language on an episode's page (board-0161, owner:
/// "clicking an episode is insane when there are immediately 12
/// buttons"). The four choices (listen or read, original or learning
/// language) became one Play, one Read and one language list: the
/// learning language's row is the one tap that makes its audio, the same
/// job as the row's second button, and once it is made Play plays it.
void main() {
  late Directory dir;
  late AppDatabase db;
  late int profileId;
  late int episode;
  late FakeEpisodePlayer player;
  late PlayerController controller;
  late Map<int, Completer<void>> held;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('trellis-four-choices');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    final feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://x.test/f', title: 'Night Sky');
    episode = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Aurora season',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://x.test/aurora.mp3',
        lang: 'en');
    await db.feedsDao.insertEpisode(
        workId: episode,
        feedId: feedId,
        guid: 'aurora',
        enclosureUrl: 'https://x.test/aurora.mp3',
        durationMs: 60 * 60000,
        publishedAtMs: 5000);
    player = FakeEpisodePlayer();
    controller = PlayerController(
        db: db, profileId: profileId, createPlayer: () => player);
    held = {};
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> transcript() async {
    await db.spineDao.insertSegments(
        episode, const [(idx: 0, kind: 'prose', text: 'Hello there.')]);
    await db.spineDao.insertAlignments(
        episode, const [(segmentIdx: 0, tStartMs: 0, tEndMs: 2000)]);
  }

  Future<void> translation(String lang) =>
      db.spineDao.upsertTranslationSentence(
          workId: episode,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: lang,
          sourceText: 'Hello there.',
          body: 'Hola.');

  ListenJobs jobs({List<String> can = const ['es', 'fr']}) => ListenJobs(
        db: db,
        chain: ListenChain(
          db: db,
          transcribe: (w, e) => transcript(),
          translate: (w, source, target, progress) async {
            progress(2, 5);
            await held[w.id]?.future;
            await translation(target);
            return null;
          },
          voiceFor: (_, lang) async => (
            name: 'Test voice',
            voiceKind: VoiceKind.machine,
            say: (String t, SpeechPace p) async =>
                SynthResult(samples: Float32List(100), sampleRate: 1000),
          ),
          audioFileFor: testServices(dir).audioFileFor,
          tempDir: Directory('${dir.path}/tmp'),
        ),
        languagesFor: ({required workLang, required feedLang}) => can,
        downloadsFor: (w, e, lang) async => const [],
        player: controller,
      );

  Future<void> pumpPage(WidgetTester tester, ListenJobs? j,
      {double width = 412, double scale = 1.0}) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    final doors = WorkDoors(
        db: db,
        profileId: profileId,
        readerDoors: ReaderDoors(player: controller),
        actions: EpisodeActions(
            db: db,
            profileId: profileId,
            player: controller,
            listenJobs: j,
            // Where a made episode's audio is, so the page knows it is here.
            services: testServices(dir)),
        transcribeRate: () => 1 / 12);
    final work = (await db.spineDao.workById(episode))!;
    final ep = await db.feedsDao.episodeOf(episode);
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: Center(
                    child: TextButton(
                        onPressed: () =>
                            doors.open(context, (work: work, episode: ep)),
                        child: const Text('open')))))));
    await tester.tap(find.text('open'));
  }

  Future<void> beats(WidgetTester tester, [int n = 10]) async {
    for (var i = 0; i < n; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // Time for the frames too: the page slides in before it can be
      // tapped where it will stand.
      await tester.pump(const Duration(milliseconds: 50));
    }
  }


  const play = Key('mode-listen');
  const read = Key('mode-read');
  const learningRow = Key('listen-in-language');

  String wordsOf(WidgetTester tester, Key key) => tester
      .widgetList<Text>(
          find.descendant(of: find.byKey(key), matching: find.byType(Text)))
      .map((t) => t.data)
      .join(' / ');

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('work-page-menu')));
    await tester.pumpAndSettle();
  }

  testWidgets('not made yet: Play is the original, Read beside it, and the '
      'learning language is a row that makes it', (tester) async {
    await db.deviceSettingsDao.write(learningLanguageKey, 'es');
    await pumpPage(tester, jobs());
    await tester.pumpAndSettle();

    expect(wordsOf(tester, play), 'Play');
    expect(
        tester.widget<Text>(find.byKey(const Key('page-play-caption'))).data,
        'English, the original');
    expect(wordsOf(tester, read), 'Read');
    expect(wordsOf(tester, learningRow),
        'Spanish / Not made yet. Tap to make the Spanish audio');
    expect(find.byKey(const Key('read-in-language')), findsNothing);
    expect(find.byKey(const Key('lang-es')), findsNothing,
        reason: 'Spanish is one row, not two');
    expect(find.text('This episode, the original'), findsOneWidget);
    expect(tester.getSize(find.byKey(learningRow)).height,
        greaterThanOrEqualTo(48));
  });

  testWidgets('the learning language’s row is the one tap: the stage and '
      'Stop show, then it plays, and Play is in Spanish from then on',
      (tester) async {
    await tester.runAsync(() async {
      await db.deviceSettingsDao.write(learningLanguageKey, 'es');
      held[episode] = Completer<void>();
      final j = jobs();
      await j.ready;
      await pumpPage(tester, j);
      await beats(tester, 25);

      await tester.tap(find.byKey(learningRow));
      await beats(tester);

      expect(
          tester
              .widget<Text>(find.byKey(const Key('listen-in-language-line')))
              .data,
          'Translating into Spanish: 2 of 5 sentences');
      expect(
          tester
              .widget<LinearProgressIndicator>(
                  find.byKey(const Key('listen-in-language-progress')))
              .value,
          closeTo(0.4, 0.001));
      expect(find.byKey(const Key('listen-in-language-stop')), findsOneWidget);

      held[episode]!.complete();
      for (var i = 0; i < 150 && controller.current == null; i++) {
        await beats(tester, 1);
      }
      await beats(tester, 25);

      expect(controller.current?.title, 'Aurora season (Spanish)');
      expect(wordsOf(tester, play), 'Play in Spanish');
      expect(
          tester.widget<Text>(find.byKey(const Key('page-play-caption'))).data,
          'Spanish, made on this phone');
      expect(find.byKey(const Key('listen-in-language-stop')), findsNothing);
      expect(find.byKey(const Key('lang-es')), findsOneWidget);
    });
  });

  testWidgets('Stop stops the job', (tester) async {
    await tester.runAsync(() async {
      await db.deviceSettingsDao.write(learningLanguageKey, 'es');
      held[episode] = Completer<void>();
      final j = jobs();
      await j.ready;
      await pumpPage(tester, j);
      await beats(tester, 25);
      await tester.tap(find.byKey(learningRow));
      await beats(tester);

      await tester.tap(find.byKey(const Key('listen-in-language-stop')));
      held[episode]!.complete();
      await beats(tester, 25);

      expect(find.byKey(const Key('listen-in-language-stop')), findsNothing);
      expect(controller.current, isNull);
    });
  });

  testWidgets('Change learning language is in the ⋮, and the row follows '
      'it', (tester) async {
    await db.deviceSettingsDao.write(learningLanguageKey, 'es');
    await pumpPage(tester, jobs());
    await tester.pumpAndSettle();

    await openMenu(tester);
    await tester.tap(find.byKey(const Key('learning-language-change')));
    await tester.pumpAndSettle();
    expect(find.text('Which language are you learning?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('learning-language-fr')));
    await tester.pumpAndSettle();

    expect(wordsOf(tester, learningRow),
        'French / Not made yet. Tap to make the French audio');
    expect(await db.deviceSettingsDao.read(learningLanguageKey), 'fr');
  });

  // Board-0128: with one language offered, Change still opens the list
  // and its note on why the others are missing.
  testWidgets('Change is offered even when only one language is', (tester) async {
    await db.deviceSettingsDao.write(learningLanguageKey, 'es');
    await pumpPage(tester, jobs(can: const ['es']));
    await tester.pumpAndSettle();

    await openMenu(tester);
    await tester.tap(find.byKey(const Key('learning-language-change')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('learning-language-dialog')), findsOneWidget);
    expect(find.byKey(const Key('learning-language-es')), findsOneWidget);
  });

  testWidgets('with no learning language yet the row says so, and a tap '
      'asks which', (tester) async {
    await pumpPage(tester, jobs());
    await tester.pumpAndSettle();

    expect(wordsOf(tester, learningRow),
        'Another language / Choose a language to make this episode in');
    await openMenu(tester);
    expect(find.byKey(const Key('learning-language-change')), findsNothing);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(learningRow));
    await tester.pumpAndSettle();
    expect(find.text('Which language are you learning?'), findsOneWidget);
  });

  testWidgets('a Spanish text with no audio: its row chooses it, and Read '
      'opens the translation', (tester) async {
    await db.deviceSettingsDao.write(learningLanguageKey, 'es');
    await transcript();
    await translation('es');
    await pumpPage(tester, jobs());
    await tester.pumpAndSettle();

    expect(wordsOf(tester, learningRow),
        'Spanish / Text only. Tap to make the Spanish audio');
    await tester.tap(find.byKey(learningRow));
    await tester.pumpAndSettle();
    expect((await db.spineDao.workById(episode))!.readLang, 'es');
    expect(
        tester.widget<Text>(find.byKey(const Key('page-play-caption'))).data,
        'There is no Spanish audio here, so Play is the original, in '
        'English.');

    await tester.tap(find.byKey(read));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderScreen), findsOneWidget);
  });

  testWidgets('Play plays the episode itself while a language with no '
      'audio is chosen, and says so', (tester) async {
    await db.deviceSettingsDao.write(learningLanguageKey, 'es');
    await transcript();
    await translation('de');
    await db.spineDao.setReadLang(episode, 'de');
    await pumpPage(tester, jobs());
    await tester.pumpAndSettle();

    expect(
        tester.widget<Text>(find.byKey(const Key('page-play-caption'))).data,
        'There is no German audio here, so Play is the original, in '
        'English.');
    await tester.tap(find.byKey(play));
    await tester.pumpAndSettle();

    expect(find.byType(ReaderScreen), findsNothing);
    expect(controller.current?.id, episode);
    expect(player.loadedUrl, 'https://x.test/aurora.mp3');
  });

  testWidgets('another language’s translation keeps its row, and Translate '
      'that can’t run is one line, never a greyed button', (tester) async {
    await db.deviceSettingsDao.write(learningLanguageKey, 'es');
    await transcript();
    await translation('es');
    await translation('de');
    await pumpPage(tester, jobs());
    await tester.pumpAndSettle();

    expect(find.text('This episode in other languages'), findsOneWidget);
    expect(find.byKey(const Key('lang-de')), findsOneWidget);
    expect(find.byKey(const Key('lang-es')), findsNothing);
    expect(find.byKey(const Key('lang-translate')), findsNothing);
    expect(find.byKey(const Key('lang-translate-why')), findsOneWidget);
  });

  testWidgets('an episode that cannot be made in the learning language has '
      'no row for it, and its languages below', (tester) async {
    await db.deviceSettingsDao.write(learningLanguageKey, 'es');
    await pumpPage(tester, jobs(can: const []));
    await tester.pumpAndSettle();

    expect(find.byKey(learningRow), findsNothing);
    expect(wordsOf(tester, play), 'Play');
    expect(find.text('This episode in other languages'), findsOneWidget);
    expect(find.byKey(const Key('lang-original')), findsOneWidget);
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('Play, Read and the learning row fit a 320dp phone at '
        '${scale}x text', (tester) async {
      await db.deviceSettingsDao.write(learningLanguageKey, 'pt');
      await pumpPage(tester, jobs(can: const ['es', 'pt']),
          width: 320, scale: scale);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      for (final k in [play, read, learningRow]) {
        await tester.ensureVisible(find.byKey(k));
        final r = tester.getRect(find.byKey(k));
        expect(r.left, greaterThanOrEqualTo(0));
        expect(r.right, lessThanOrEqualTo(320));
        expect(r.height, greaterThanOrEqualTo(48));
      }
    });
  }
}
