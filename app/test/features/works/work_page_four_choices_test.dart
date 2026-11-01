import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/episodes/episode_actions.dart';
import 'package:trellis/features/listen/listen_chain.dart';
import 'package:trellis/features/listen/listen_jobs.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/reader/reader_doors.dart';
import 'package:trellis/features/reader/reader_screen.dart';
import 'package:trellis/features/reader/speech/speech_engine.dart';
import 'package:trellis/features/works/work_open.dart';

import '../../support/fake_player.dart';
import '../../support/fake_services.dart';

/// The episode's page holds the four choices as one group (board ruling,
/// option B): listen or read, in the original or in the learning
/// language. Listening in the learning language is the same one tap as
/// the row's second button, with the same job behind it.
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
            say: (String t) async =>
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
            db: db, profileId: profileId, player: controller, listenJobs: j),
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

  const listenOriginal = Key('mode-listen');
  const readOriginal = Key('mode-read');
  const listenLearning = Key('listen-in-language');
  const readLearning = Key('read-in-language');

  String wordsOf(WidgetTester tester, Key key) => tester
      .widgetList<Text>(
          find.descendant(of: find.byKey(key), matching: find.byType(Text)))
      .map((t) => t.data)
      .join(' / ');

  testWidgets('an episode that can be made shows four choices as one '
      'group: listen or read, in the original or the learning language',
      (tester) async {
    await db.deviceSettingsDao.write(learningLanguageKey, 'es');
    await pumpPage(tester, jobs());
    await tester.pumpAndSettle();

    expect(wordsOf(tester, listenOriginal), 'Listen / Original');
    expect(wordsOf(tester, listenLearning), 'Listen / Spanish');
    expect(wordsOf(tester, readOriginal), 'Read / Original');
    expect(wordsOf(tester, readLearning), 'Read / Spanish');

    // Two by two: listening above reading, the original on the left.
    final lo = tester.getRect(find.byKey(listenOriginal));
    final ll = tester.getRect(find.byKey(listenLearning));
    final ro = tester.getRect(find.byKey(readOriginal));
    final rl = tester.getRect(find.byKey(readLearning));
    expect(lo.top, ll.top);
    expect(ro.top, rl.top);
    expect(lo.right, lessThanOrEqualTo(ll.left));
    expect(lo.bottom, lessThanOrEqualTo(ro.top));
    expect(lo.left, ro.left);
    expect(ll.left, rl.left);
    for (final r in [lo, ll, ro, rl]) {
      expect(r.height, greaterThanOrEqualTo(48));
    }

    // Nothing twice: the original is a column of the group, not also a
    // button in a Language section, and there is no second bar.
    expect(find.byKey(const Key('lang-original')), findsNothing);
    expect(find.text('Language'), findsNothing);
    expect(find.byTooltip('Listen in Spanish'), findsOneWidget);
    expect(find.bySemanticsLabel('Listen in Spanish'), findsOneWidget);
  });

  testWidgets('listening in the learning language is the one tap: it '
      'shows the stage and Stop under the group, then plays, and says it '
      'is ready', (tester) async {
    await tester.runAsync(() async {
      await db.deviceSettingsDao.write(learningLanguageKey, 'es');
      held[episode] = Completer<void>();
      final j = jobs();
      await j.ready;
      await pumpPage(tester, j);
      await beats(tester, 25);

      await tester.tap(find.byKey(listenLearning));
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
      expect(find.byKey(const Key('learning-language-change')), findsNothing);
      expect(find.byTooltip('Making it in Spanish: translating, 40%'),
          findsOneWidget);

      held[episode]!.complete();
      for (var i = 0; i < 150 && controller.current == null; i++) {
        await beats(tester, 1);
      }
      await beats(tester, 25);

      expect(controller.current?.title, 'Aurora season (Spanish)');
      expect(
          tester
              .widget<Text>(find.byKey(const Key('listen-in-language-line')))
              .data,
          'Spanish is ready. The voice is machine made.');
      expect(find.byTooltip('Play in Spanish'), findsOneWidget);
      // The translation the job made is there to read at once.
      expect(
          tester
              .widget<ButtonStyleButton>(find.byKey(readLearning))
              .onPressed,
          isNotNull);
    });
  });

  testWidgets('Stop under the group stops the job', (tester) async {
    await tester.runAsync(() async {
      await db.deviceSettingsDao.write(learningLanguageKey, 'es');
      held[episode] = Completer<void>();
      final j = jobs();
      await j.ready;
      await pumpPage(tester, j);
      await beats(tester, 25);
      await tester.tap(find.byKey(listenLearning));
      await beats(tester);

      await tester.tap(find.byKey(const Key('listen-in-language-stop')));
      held[episode]!.complete();
      await beats(tester, 25);

      expect(find.byKey(const Key('listen-in-language-stop')), findsNothing);
      expect(find.byTooltip('Listen in Spanish'), findsOneWidget);
      expect(controller.current, isNull);
    });
  });

  testWidgets('Change keeps its place, and both learning-language choices '
      'follow it', (tester) async {
    await db.deviceSettingsDao.write(learningLanguageKey, 'es');
    await pumpPage(tester, jobs());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('learning-language-change')));
    await tester.pumpAndSettle();
    expect(find.text('Which language are you learning?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('learning-language-fr')));
    await tester.pumpAndSettle();

    expect(wordsOf(tester, listenLearning), 'Listen / French');
    expect(wordsOf(tester, readLearning), 'Read / French');
    expect(await db.deviceSettingsDao.read(learningLanguageKey), 'fr');
  });

  testWidgets('with no learning language yet the second column says so, '
      'and its Listen asks which', (tester) async {
    await pumpPage(tester, jobs());
    await tester.pumpAndSettle();

    expect(wordsOf(tester, listenLearning), 'Listen / Another language');
    expect(wordsOf(tester, readLearning), 'Read / Another language');
    expect(find.byKey(const Key('learning-language-change')), findsNothing);

    await tester.tap(find.byKey(listenLearning));
    await tester.pumpAndSettle();
    expect(find.text('Which language are you learning?'), findsOneWidget);
  });

  testWidgets('Read in the learning language opens the translation when '
      'there is one', (tester) async {
    await db.deviceSettingsDao.write(learningLanguageKey, 'es');
    await transcript();
    await translation('es');
    await pumpPage(tester, jobs());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(readLearning));
    await tester.pumpAndSettle();

    expect(find.byType(ReaderScreen), findsOneWidget);
    expect((await db.spineDao.workById(episode))!.readLang, 'es');
  });

  testWidgets('with no transcript yet, Read in the learning language is '
      'off and says what makes it', (tester) async {
    await db.deviceSettingsDao.write(learningLanguageKey, 'es');
    await pumpPage(tester, jobs());
    await tester.pumpAndSettle();

    expect(
        tester.widget<ButtonStyleButton>(find.byKey(readLearning)).onPressed,
        isNull);
    expect(
        find.text('Read in Spanish: A translation needs a transcript first. '
            'Listen in Spanish makes both.'),
        findsOneWidget);
  });

  testWidgets('Listen in the original plays the episode itself, even after '
      'a translation was the last thing read', (tester) async {
    await db.deviceSettingsDao.write(learningLanguageKey, 'es');
    await transcript();
    await translation('de');
    await db.spineDao.setReadLang(episode, 'de');
    await pumpPage(tester, jobs());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(listenOriginal));
    await tester.pumpAndSettle();

    expect(find.byType(ReaderScreen), findsNothing);
    expect(controller.current?.id, episode);
    expect(player.loadedUrl, 'https://x.test/aurora.mp3');
  });

  testWidgets('a translation in some other language keeps its door, under '
      'Other languages', (tester) async {
    await db.deviceSettingsDao.write(learningLanguageKey, 'es');
    await transcript();
    await translation('es');
    await translation('de');
    await pumpPage(tester, jobs());
    await tester.pumpAndSettle();

    expect(find.text('Other languages'), findsOneWidget);
    expect(find.byKey(const Key('lang-de')), findsOneWidget);
    // The learning language is in the group above, not here again.
    expect(find.byKey(const Key('lang-es')), findsNothing);
    expect(find.byKey(const Key('lang-translate')), findsOneWidget);
  });

  testWidgets('an episode that cannot be made in the learning language '
      'keeps the page it had: two ways in, and the Language section',
      (tester) async {
    await db.deviceSettingsDao.write(learningLanguageKey, 'es');
    await pumpPage(tester, jobs(can: const []));
    await tester.pumpAndSettle();

    expect(find.byKey(listenLearning), findsNothing);
    expect(find.byKey(readLearning), findsNothing);
    expect(wordsOf(tester, listenOriginal), 'Listen');
    expect(find.text('Language'), findsOneWidget);
    expect(find.byKey(const Key('lang-original')), findsOneWidget);
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('the four choices fit a 320dp phone at ${scale}x text',
        (tester) async {
      await db.deviceSettingsDao.write(learningLanguageKey, 'pt');
      await pumpPage(tester, jobs(can: const ['es', 'pt']),
          width: 320, scale: scale);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      for (final k in [listenOriginal, listenLearning, readOriginal, readLearning]) {
        final r = tester.getRect(find.byKey(k));
        expect(r.left, greaterThanOrEqualTo(0));
        expect(r.right, lessThanOrEqualTo(320));
        expect(r.height, greaterThanOrEqualTo(48));
      }
      expect(find.byKey(const Key('learning-language-change')), findsOneWidget);
    });
  }
}
