import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jobs_core/jobs_core.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/episodes/episode_actions.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/reader/reader_doors.dart';
import 'package:trellis/features/transcribe/transcribe_coordinator.dart';
import 'package:trellis/features/transcribe/transcript_so_far.dart';
import 'package:trellis/features/works/work_menu.dart';
import 'package:trellis/features/works/work_open.dart';
import 'package:trellis/features/works/work_row.dart';

import '../../support/fake_player.dart';
import '../../support/fake_services.dart';
import '../../support/fake_translation_service.dart';

/// A transcript shown as it is made (1.6.9) is part of one until its job
/// ends. Rows, menus and the episode's page must say so: a row says how
/// far it has got instead of "Transcript", the ⋮ offers no "Transcribe
/// again" over a live job, and Translate waits for the whole text.
void main() {
  late AppDatabase db;
  late int profileId;
  late int workId;
  late WorkEntry entry;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    final feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://x.test/f', title: 'Show');
    await db.customStatement(
        'UPDATE feeds SET language = ? WHERE id = ?', ['es', feedId]);
    workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Ep',
        persistence: 'work',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://x.test/1.mp3');
    await db.feedsDao.insertEpisode(
        workId: workId,
        feedId: feedId,
        guid: 'g',
        enclosureUrl: 'https://x.test/1.mp3',
        durationMs: 40 * 60000,
        publishedAtMs: 1);
    entry = (
      work: (await db.spineDao.workById(workId))!,
      episode: await db.feedsDao.episodeOf(workId),
    );
  });
  tearDown(() => db.close());

  Future<void> transcribeSoFar() async {
    await db.spineDao.insertSegments(
        workId, const [(idx: 0, kind: 'prose', text: 'Hola.')]);
    await db.spineDao.insertAlignments(
        workId, const [(segmentIdx: 0, tStartMs: 0, tEndMs: 12 * 60000 + 5)]);
  }

  Future<void> job(JobState state, {bool soFar = true}) async {
    await db.jobsDao.save(Job(
        id: transcribeJobId(workId),
        kind: 'transcribe',
        state: state,
        checkpoint: null,
        totalUnits: 9,
        doneUnits: 2,
        createdAtMs: 5));
    await db.jobsDao.setPayload(transcribeJobId(workId),
        jsonEncode({'workId': workId, 'soFar': soFar}));
  }

  group('a list knows each transcript’s stage in one pass', () {
    Future<TranscriptStage> stage() async =>
        (await WorkListState.load(db, profileId, entries: [entry]))
            .transcriptOf(workId);

    test('none, then being made, stopped part way, and whole', () async {
      expect(await stage(), TranscriptStage.none);
      await transcribeSoFar();
      await job(JobState.running);
      expect(await stage(), TranscriptStage.makingNow);
      final making = await transcriptsMaking(db);
      expect(making[workId], (running: true, soFarMs: 12 * 60000 + 5));
      await job(JobState.cancelled);
      expect(await stage(), TranscriptStage.stoppedPartWay);
      await job(JobState.failed);
      expect(await stage(), TranscriptStage.stoppedPartWay);
      await db.jobsDao.deleteJob(transcribeJobId(workId));
      expect(await stage(), TranscriptStage.whole);
    });

    test('a job over an old transcript leaves it whole', () async {
      await transcribeSoFar();
      await job(JobState.running, soFar: false);
      expect(await stage(), TranscriptStage.whole);
      expect(await transcriptsMaking(db), isEmpty);
    });
  });

  group('the row’s marker', () {
    Future<List<String>> labels(WidgetTester tester) async {
      final state = await tester.runAsync(
          () => WorkListState.load(db, profileId, entries: [entry]));
      final facts = WorkRowFacts.of(entry.work, entry.episode, state!);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Wrap(
                  children: workMarkers(ThemeData(), facts, workId)))));
      return [
        for (final t in tester.widgetList<Text>(find.descendant(
            of: find.byKey(Key('transcribed-$workId')),
            matching: find.byType(Text))))
          t.data!,
      ];
    }

    testWidgets('says how far a transcript being made has got',
        (tester) async {
      await tester.runAsync(() async {
        await transcribeSoFar();
        await job(JobState.running);
      });
      expect(await labels(tester), ['Transcribing, 12 of 40 min']);
      expect(find.text('Transcript'), findsNothing);
    });

    testWidgets('says a stopped one is part of a transcript', (tester) async {
      await tester.runAsync(() async {
        await transcribeSoFar();
        await job(JobState.cancelled);
      });
      expect(await labels(tester), ['Part transcript, 12 of 40 min']);
    });

    testWidgets('says Transcript once it is whole', (tester) async {
      await tester.runAsync(transcribeSoFar);
      expect(await labels(tester), ['Transcript']);
    });

    test('without a length it says minutes so far', () {
      expect(transcriptMarkerLabel((running: true, soFarMs: 61000), null),
          'Transcribing, 1 min so far');
      expect(transcriptMarkerLabel((running: false, soFarMs: 61000), 0),
          'Part transcript, 1 min so far');
      expect(transcriptMarkerLabel(null, 40 * 60000), 'Transcript');
    });
  });

  group('the ⋮', () {
    late EpisodeActions actions;
    setUp(() {
      actions = EpisodeActions(
          db: db,
          profileId: profileId,
          transcriber: TranscribeCoordinator(
              db: db, services: testServices(Directory.systemTemp)),
          useDefaultShare: false);
    });

    Map<String, String> items(TranscriptStage stage) => {
          for (final i in workMenuItems(actions, entry,
                  transcript: stage, sourceLang: 'es')
              .whereType<PopupMenuItem<String>>())
            i.value!: (i.child! as Text).data!,
        };

    test('offers no Transcribe while the job runs, and no translate',
        () {
      final m = items(TranscriptStage.makingNow);
      expect(m.keys, isNot(contains('transcribe')));
      expect(m.keys, isNot(contains('translate')));
    });

    test('offers to resume a stopped one, not to start again', () {
      final m = items(TranscriptStage.stoppedPartWay);
      expect(m['transcribe'], 'Resume transcribing');
      expect(m.keys, isNot(contains('translate')));
    });

    test('Transcribe again and translate wait for the whole transcript', () {
      expect(items(TranscriptStage.none)['transcribe'], 'Transcribe');
      final whole = items(TranscriptStage.whole);
      expect(whole['transcribe'], 'Transcribe again');
      expect(whole.keys, contains('translate'));
    });
  });

  group('the episode’s page', () {
    late PlayerController controller;
    late Directory dir;
    setUp(() {
      controller = PlayerController(
          db: db, profileId: profileId, createPlayer: () => FakeEpisodePlayer());
      dir = Directory.systemTemp.createTempSync('trellis-partial');
    });
    tearDown(() {
      controller.dispose();
      dir.deleteSync(recursive: true);
    });

    Future<void> pumpPage(WidgetTester tester) async {
      final services = testServices(dir);
      final actions = EpisodeActions(
          db: db,
          profileId: profileId,
          player: controller,
          transcriber: TranscribeCoordinator(db: db, services: services),
          services: services,
          transcribeRate: () => 1 / 12);
      final doors = WorkDoors(
          db: db,
          profileId: profileId,
          readerDoors: ReaderDoors(
              player: controller,
              translation: FakeTranslation().service),
          actions: actions,
          openLink: (_) async {},
          transcribeRate: () => 1 / 12);
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                  body: Center(
                      child: TextButton(
                          onPressed: () => doors.open(context, entry),
                          child: const Text('open')))))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('Translate waits for the whole transcript, and says so',
        (tester) async {
      await tester.runAsync(() async {
        await transcribeSoFar();
        await job(JobState.running);
      });
      await pumpPage(tester);
      final translate = tester
          .widget<ButtonStyleButton>(find.byKey(const Key('lang-translate')));
      expect(translate.onPressed, isNull);
      expect(
          find.text('Translate waits for the whole transcript: 12 of 40 min '
              'is done.'),
          findsOneWidget);
    });

    testWidgets('a whole transcript can be translated', (tester) async {
      await tester.runAsync(transcribeSoFar);
      await pumpPage(tester);
      final translate = tester
          .widget<ButtonStyleButton>(find.byKey(const Key('lang-translate')));
      expect(translate.onPressed, isNotNull);
    });

    testWidgets('the page offers Translate once the job ends, without being '
        'reopened', (tester) async {
      await tester.runAsync(() async {
        await transcribeSoFar();
        await job(JobState.running);
      });
      await pumpPage(tester);
      await tester.runAsync(
          () => db.jobsDao.deleteJob(transcribeJobId(workId)));
      await tester.pumpAndSettle();
      final translate = tester
          .widget<ButtonStyleButton>(find.byKey(const Key('lang-translate')));
      expect(translate.onPressed, isNotNull);
    });
  });
}
