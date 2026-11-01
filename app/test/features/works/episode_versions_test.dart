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
import 'package:trellis/services/device_services.dart';

import '../../support/fake_player.dart';
import '../../support/fake_services.dart';

/// Board-0130, owner: on an episode made in Spanish, tapping Spanish
/// opened the transcript with English and Spanish words while the audio
/// stayed English; he expected the Spanish audio. "maybe make it clear
/// how the episodes are related/have a sister episodes section or
/// something that it auto jumps to?"
///
/// The episode's page lists it in every language it has, each saying
/// whether its audio is on the phone; since 1.6.18 a made language is a
/// version with no page of its own, and opening one opens this page in
/// its language. A language with audio becomes what Play plays. A
/// translation read with no audio says so at the top of the reader, with
/// the one tap that makes it.
void main() {
  late Directory dir;
  late AppDatabase db;
  late DeviceServices services;
  late int profileId;
  late int feedId;
  late int original;
  late FakeEpisodePlayer player;
  late PlayerController controller;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('trellis-versions');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    services = testServices(dir);
    profileId = await db.profilesDao.create('Ada');
    feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://x.test/f', title: 'Night Sky');
    original = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Aurora season',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://x.test/aurora.mp3',
        lang: 'en');
    await db.feedsDao.insertEpisode(
        workId: original,
        feedId: feedId,
        guid: 'aurora',
        enclosureUrl: 'https://x.test/aurora.mp3',
        durationMs: 60 * 60000,
        publishedAtMs: 5000);
    await db.spineDao.insertSegments(
        original, const [(idx: 0, kind: 'prose', text: 'Hello there.')]);
    await db.spineDao.insertAlignments(
        original, const [(segmentIdx: 0, tStartMs: 0, tEndMs: 2000)]);
    player = FakeEpisodePlayer();
    controller = PlayerController(
        db: db, profileId: profileId, createPlayer: () => player);
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> translation(int workId, String lang, String body) =>
      db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: lang,
          sourceText: 'Hello there.',
          body: body);

  /// A made language in [lang], stored as the one tap stores it since
  /// 1.6.18 (a version, no episode row), with its audio
  /// on the phone unless [audio] is false.
  Future<int> madeIn(String lang, {bool audio = true}) async {
    final url = 'https://spoken.trellis.invalid/$original-$lang.ogg';
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'version',
        title: 'Aurora season ($lang)',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: url,
        lang: lang);
    await db.versionsDao.put(workId: id, originalId: original, lang: lang);
    await db.spineDao.insertSegments(
        id, const [(idx: 0, kind: 'prose', text: 'Hola.')]);
    await db.spineDao.insertAlignments(
        id, const [(segmentIdx: 0, tStartMs: 0, tEndMs: 900)]);
    if (audio) {
      services.audioFileFor(id, url)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);
    }
    return id;
  }

  ListenJobs jobs({List<String> can = const ['es', 'fr']}) => ListenJobs(
        db: db,
        chain: ListenChain(
          db: db,
          transcribe: (w, e) async {},
          translate: (w, source, target, progress) async => null,
          voiceFor: (_, lang) async => (
            name: 'Test voice',
            voiceKind: VoiceKind.machine,
            say: (String t, SpeechPace p) async =>
                SynthResult(samples: Float32List(100), sampleRate: 1000),
          ),
          audioFileFor: services.audioFileFor,
          tempDir: Directory('${dir.path}/tmp'),
        ),
        languagesFor: ({required workLang, required feedLang}) => can,
        downloadsFor: (w, e, lang) async => const [],
        player: controller,
      );

  Future<void> pumpPage(WidgetTester tester, int workId, ListenJobs? j) async {
    tester.view.physicalSize = const Size(412, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final doors = WorkDoors(
        db: db,
        profileId: profileId,
        readerDoors: ReaderDoors(player: controller),
        actions: EpisodeActions(
            db: db,
            profileId: profileId,
            player: controller,
            services: services,
            listenJobs: j),
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

  String said(WidgetTester tester, Key key) => tester
      .widgetList<Text>(
          find.descendant(of: find.byKey(key), matching: find.byType(Text)))
      .map((t) => t.data)
      .join(' / ');

  testWidgets('the original’s page lists itself and every other language, '
      'each saying whether its audio is on the phone', (tester) async {
    await madeIn('es');
    await translation(original, 'de', 'Hallo.');
    await pumpPage(tester, original, null);

    expect(find.text('This episode in other languages'), findsOneWidget);
    expect(said(tester, const Key('lang-original')),
        'English / This episode, the original');
    expect(said(tester, const Key('lang-es')),
        'Spanish / Audio on this phone');
    expect(said(tester, const Key('lang-de')),
        'German / Text only, no audio yet');
  });

  // Board-0161: the language list is the one switch for listening and
  // reading; a row chooses, Play plays.
  testWidgets('tapping a language with audio makes it Play’s: Play plays '
      'that episode, from this page', (tester) async {
    final spanish = await madeIn('es');
    await pumpPage(tester, original, null);

    await tester.tap(find.byKey(const Key('lang-es')));
    await tester.pumpAndSettle();
    expect(said(tester, const Key('mode-listen')), 'Play in Spanish');
    await tester.tap(find.byKey(const Key('mode-listen')));
    await tester.pumpAndSettle();

    expect(controller.current?.id, spanish);
    expect(
        tester.widget<Text>(find.byKey(const Key('work-page-title'))).data,
        'Aurora season');
  });

  // 1.6.18, owner: "it should live together". A made language has no
  // page of its own: opening it opens its episode's page, in its language.
  testWidgets('opening a made language opens its episode’s page, in that '
      'language; the original is one tap away', (tester) async {
    final spanish = await madeIn('es');
    await madeIn('fr', audio: false);
    await pumpPage(tester, spanish, null);

    expect(
        tester.widget<Text>(find.byKey(const Key('work-page-title'))).data,
        'Aurora season');
    expect(said(tester, const Key('mode-listen')), 'Play in Spanish');
    expect(said(tester, const Key('lang-original')),
        'English / This episode, the original');
    expect(said(tester, const Key('lang-es')),
        'Spanish / Audio on this phone');
    expect(said(tester, const Key('lang-fr')),
        'French / Text only, its audio was removed');

    await tester.tap(find.byKey(const Key('lang-original')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mode-listen')));
    await tester.pumpAndSettle();
    expect(controller.current?.id, original);
  });

  testWidgets('reading a translation with no audio says so at the top of '
      'the reader, with the one tap that makes it', (tester) async {
    await tester.runAsync(() async {
      await db.deviceSettingsDao.write(learningLanguageKey, 'fr');
      await translation(original, 'es', 'Hola.');
      final j = jobs();
      await j.ready;
      await pumpPage(tester, original, j);

      await tester.tap(find.byKey(const Key('lang-es')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(find.byKey(const Key('mode-read')));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.byType(ReaderScreen), findsOneWidget);
      expect(
          tester.widget<Text>(find.byKey(const Key('reader-note-text'))).data,
          'This is the Spanish text. There is no Spanish audio yet.');
      final make = find.byKey(const Key('reader-note-action'));
      expect(said(tester, const Key('reader-note-action')),
          'Make the Spanish audio');
      expect(tester.getSize(make).height, greaterThanOrEqualTo(48));
      await tester.tap(make);
      for (var i = 0; i < 150 && controller.current == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 50));
      }

      // Made in Spanish, though French is the learning language, and
      // played once made.
      expect(controller.current?.title, 'Aurora season (Spanish)');
      await j.stopAll();
    });
  });

  testWidgets('the learning language made: the page opens on it, and Read '
      'says its audio is here, and plays it', (tester) async {
    await db.deviceSettingsDao.write(learningLanguageKey, 'es');
    await translation(original, 'es', 'Hola.');
    final spanish = await madeIn('es');
    final j = jobs();
    await tester.runAsync(() => j.ready);
    await pumpPage(tester, original, j);

    // Made, so the page opens on Spanish: Read reads it.
    expect(said(tester, const Key('mode-listen')), 'Play in Spanish');
    await tester.tap(find.byKey(const Key('mode-read')));
    await tester.pumpAndSettle();

    expect(find.byType(ReaderScreen), findsOneWidget);
    expect(
        tester.widget<Text>(find.byKey(const Key('reader-note-text'))).data,
        'This is the Spanish text, with its Spanish audio.');
    await tester.tap(find.byKey(const Key('reader-note-action')));
    await tester.pumpAndSettle();
    expect(controller.current?.id, spanish);
  });
}
