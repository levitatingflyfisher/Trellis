import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhearth_design/openhearth_design.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/episodes/episode_actions.dart';
import 'package:trellis/features/feeds/episode_download_coordinator.dart';
import 'package:trellis/features/listen/listen_chain.dart';
import 'package:trellis/features/listen/listen_jobs.dart';
import 'package:trellis/features/listen/spoken_episode.dart' show VoiceKind;
import 'package:trellis/features/player/play_fetch.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/reader/reader_doors.dart';
import 'package:trellis/features/reader/speech/speech_engine.dart';
import 'package:trellis/features/transcribe/transcribe_coordinator.dart';
import 'package:trellis/features/works/notes_view.dart';
import 'package:trellis/features/works/work_open.dart';
import 'package:trellis/features/works/work_page.dart';
import 'package:trellis/services/device_services.dart';

import '../../support/fake_player.dart';
import '../../support/fake_services.dart';

/// The owner, 12 Nov: "clicking an episode is insane when there are
/// immediately 12 buttons. Listen original. listen spanish. read
/// original. read spanish. change. download then play. english, this
/// episode, the original. greyed out translate. play next. play last.
/// keep. transcribe. download", "all formatted CRAZILY".
///
/// The page now has one obvious main action, Play, and three beside it
/// (Read, Queue, Download); the language list below is the one switch for
/// listening and reading; everything else is in the ⋮. No control is
/// ever shown greyed out: where something is not offered, a plain line
/// says why.
void main() {
  late Directory dir;
  late AppDatabase db;
  late int profileId;
  late int episode;
  late DeviceServices services;
  late EpisodeDownloadCoordinator downloads;
  late FakeEpisodePlayer player;
  late PlayerController controller;
  const url = 'https://x.test/aurora.mp3';

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('trellis-page-layout');
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
        sourceUrl: url,
        lang: 'en');
    await db.feedsDao.insertEpisode(
        workId: episode,
        feedId: feedId,
        guid: 'aurora',
        enclosureUrl: url,
        durationMs: 60 * 60000,
        publishedAtMs: 5000);
    await db.feedsDao.fillNotes(episode,
        html: '<p>Lights over the harbour.</p>',
        plain: 'Lights over the harbour.');
    services = testServices(dir, audioFetcher: ControllableAudioFetcher());
    downloads = EpisodeDownloadCoordinator(services: services, db: db);
    player = FakeEpisodePlayer();
    controller = PlayerController(
        db: db,
        profileId: profileId,
        createPlayer: () => player,
        localAudioFileFor: services.audioFileFor,
        downloadFirst: () async => false,
        beginFetch: (work, u) => beginEpisodeFetch(downloads, work, u));
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
    dir.deleteSync(recursive: true);
  });

  ListenJobs jobs() => ListenJobs(
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
        languagesFor: ({required workLang, required feedLang}) =>
            const ['es', 'fr'],
        downloadsFor: (w, e, lang) async => const [],
        player: controller,
      );

  Future<void> pumpPage(WidgetTester tester,
      {double width = 412, double height = 2400, double scale = 1.0}) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await db.deviceSettingsDao.write(learningLanguageKey, 'es');
    final actions = EpisodeActions(
        db: db,
        profileId: profileId,
        player: controller,
        downloader: downloads,
        transcriber: TranscribeCoordinator(db: db, services: services),
        services: services,
        listenJobs: jobs(),
        transcribeRate: () => 1 / 12);
    final doors = WorkDoors(
        db: db,
        profileId: profileId,
        readerDoors: ReaderDoors(player: controller),
        actions: actions,
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
    await tester.pumpAndSettle();
  }

  /// Every control the page shows, by its words, as the owner counted
  /// them: buttons (greyed ones too), tappable rows and the ⋮. Links in
  /// the show notes are the notes' own, not the page's.
  List<String> controls(WidgetTester tester) {
    final page = find.byType(WorkPage);
    final notes = find.byType(NotesView);
    Finder self(Element e) => find.byElementPredicate((x) => x == e);
    String words(Element e) => [
          for (final t in find
              .descendant(of: self(e), matching: find.byType(Text))
              .evaluate())
            (t.widget as Text).data ?? '',
        ].where((w) => w.isNotEmpty).join(' / ');
    final bar = find.byType(AppBar);
    return [
      for (final e in find
          .descendant(
              of: page,
              matching: find.byWidgetPredicate((w) =>
                  w is ButtonStyleButton ||
                  w is IconButton ||
                  w is OhBarOverflow ||
                  (w is ListTile && w.onTap != null)))
          .evaluate())
        if (find
                .descendant(of: notes, matching: self(e))
                .evaluate()
                .isEmpty &&
            // The bar's Back is the app's, not the page's; its ⋮ counts.
            (e.widget is OhBarOverflow ||
                find.descendant(of: bar, matching: self(e)).evaluate().isEmpty))
          switch (e.widget) {
            ButtonStyleButton(onPressed: null) => 'greyed: ${words(e)}',
            OhBarOverflow() => '⋮',
            _ => words(e).isEmpty
                ? (e.widget is IconButton
                    ? (e.widget as IconButton).tooltip ?? 'icon ${e.widget.key}'
                    : 'row ${e.widget.key}')
                : words(e),
          },
    ];
  }

  testWidgets('the owner’s episode (learning Spanish, not made, not '
      'downloaded, no transcript): one main action and few beside it',
      (tester) async {
    await pumpPage(tester);
    final shown = controls(tester);
    debugPrint('page-controls (${shown.length}): ${shown.join(' | ')}');

    expect(shown.where((c) => c.startsWith('greyed')), isEmpty,
        reason: 'a greyed-out control is never shown');
    final filled = find.descendant(
        of: find.byType(WorkPage), matching: find.byType(FilledButton));
    expect(filled, findsOneWidget, reason: 'one obvious main action');
    expect(
        find.descendant(of: filled, matching: find.text('Play')),
        findsOneWidget);
    expect(shown.length, lessThanOrEqualTo(8));
  });

  testWidgets('beside Play: Read, Queue and Download, side by side on one '
      'grid line, each at least 48 high', (tester) async {
    await pumpPage(tester);
    final play = tester.getRect(find.byKey(const Key('mode-listen')));
    final row = [
      tester.getRect(find.byKey(const Key('mode-read'))),
      tester.getRect(find.byKey(Key('page-queue-$episode'))),
      tester.getRect(find.byKey(Key('page-download-$episode'))),
    ];
    for (final r in row) {
      expect(r.top, row.first.top);
      expect(r.height, greaterThanOrEqualTo(48));
      expect(r.width, closeTo(row.first.width, 1));
    }
    expect(row.first.left, closeTo(play.left, 0.5));
    expect(row.last.right, closeTo(play.right, 0.5));
    expect(row.first.top, greaterThan(play.bottom));
  });

  testWidgets('Queue holds Play next and Play last together', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(Key('page-queue-$episode')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('page-play-last-$episode')));
    await tester.pumpAndSettle();
    expect((await db.queueDao.queueOf(profileId)).single.workId, episode);
  });

  testWidgets('what is not on the page is in the ⋮: Keep, Transcribe, the '
      'other way to play, and the learning language', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const Key('work-page-menu')));
    await tester.pumpAndSettle();
    for (final words in [
      'Keep',
      'Transcribe',
      'Download, then play',
      'Change learning language',
    ]) {
      expect(find.textContaining(words), findsWidgets, reason: words);
    }
  });

  testWidgets('a text: Read is the one main action, Listen beside it, at '
      '360 dp and 1.3 text', (tester) async {
    final text = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'article',
        title: 'The marsh at dawn',
        persistence: 'work',
        firstSeenEpochDay: 100);
    await db.spineDao.insertSegments(
        text, const [(idx: 0, kind: 'prose', text: 'The marsh at dawn.')]);
    episode = text;
    await pumpPage(tester, width: 360, scale: 1.3);
    expect(tester.takeException(), isNull);
    final filled = find.descendant(
        of: find.byType(WorkPage), matching: find.byType(FilledButton));
    expect(filled, findsOneWidget);
    expect(find.descendant(of: filled, matching: find.text('Read')),
        findsOneWidget);
    expect(find.byKey(const Key('mode-listen')), findsOneWidget);
    final shown = controls(tester);
    debugPrint('text-page-controls (${shown.length}): ${shown.join(' | ')}');
    expect(shown.where((c) => c.startsWith('greyed')), isEmpty);
  });

  for (final (width, scale) in [
    (360.0, 1.3),
    (412.0, 1.3),
    (360.0, 1.0),
    (412.0, 1.0),
    (320.0, 2.0),
  ]) {
    testWidgets('at ${width.toInt()} dp and text $scale nothing overflows, '
        'every control is on screen and at least 48 high', (tester) async {
      await pumpPage(tester, width: width, scale: scale);
      expect(tester.takeException(), isNull);
      for (final f in [
        find.byKey(const Key('mode-listen')),
        find.byKey(const Key('mode-read')),
        find.byKey(Key('page-queue-$episode')),
        find.byKey(Key('page-download-$episode')),
      ]) {
        final r = tester.getRect(f);
        expect(r.left, greaterThanOrEqualTo(0));
        expect(r.right, lessThanOrEqualTo(width));
        expect(r.height, greaterThanOrEqualTo(48));
      }
      // Labels whole: one line, nothing cut.
      for (final label in ['Play', 'Read', 'Queue', 'Download']) {
        final p = tester.renderObject<RenderParagraph>(find
            .descendant(
                of: find.byType(WorkPage), matching: find.text(label))
            .first);
        expect(p.getMaxIntrinsicWidth(double.infinity),
            lessThanOrEqualTo(p.size.width + 0.5),
            reason: label);
      }
    });
  }
}
