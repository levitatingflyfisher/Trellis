import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jobs_core/jobs_core.dart';
import 'package:ml_runtime/ml_runtime.dart' show WhisperTask;
import 'package:trellis/db/database.dart';
import 'package:trellis/features/listen/listen_jobs.dart' show listenLineKey;
import 'package:trellis/features/transcribe/decoder.dart';
import 'package:trellis/features/transcribe/transcribe_coordinator.dart';
import 'package:trellis/features/transcribe/transcript_so_far.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/tabs.dart';
import '../support/fake_services.dart';
import '../support/scripted_fetcher.dart';
import '../support/pick_reader.dart';

/// The canonical user's path (P3): a podcast episode in her language →
/// synced text on the same work. The overflow menu starts it, the ONE
/// consent chokepoint fronts every download, the job runs checkpointed
/// with a live card (chunks done/total + ETA), kill/resume works from the
/// UI, and the result replaces the episode's spine rows.
void main() {
  late AppDatabase db;
  late Directory tmp;
  late FakeEpisodePlayer player;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('trellis-flow');
    player = FakeEpisodePlayer();
  });
  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  const enclosure = 'https://cast.example.test/ep1.mp3';

  /// [transcribed] gives it a transcript already: Whisper's
  /// translate-to-English is offered only then (1.5.8, the work page's
  /// rule on every row).
  Future<({int profileId, int workId})> seedEpisode(
      {bool transcribed = false}) async {
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
        sourceUrl: enclosure);
    await db.spineDao.insertSegments(
        workId, const [(idx: 0, kind: 'prose', text: 'Show notes.')]);
    await db.feedsDao.insertEpisode(
        workId: workId,
        feedId: feedId,
        guid: 'ep1',
        enclosureUrl: enclosure,
        publishedAtMs: DateTime.utc(2026, 8, 1).millisecondsSinceEpoch);
    if (transcribed) {
      await db.spineDao.insertAlignments(
          workId, const [(segmentIdx: 0, tStartMs: 0, tEndMs: 1000)]);
    }
    return (profileId: profileId, workId: workId);
  }

  Future<void> openRiver(WidgetTester tester, dynamic services) async {
    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((u, h) => textResponse('')),
        createPlayer: () => player,
        services: services));
    await tester.pumpAndSettle();
    await pickReader(tester, 'Ada');
    await tester.tap(tabLabel('Latest'));
    await tester.pumpAndSettle();
  }

  /// Pause, Try again and Discard live on the Jobs page; Latest only says
  /// what is going on.
  Future<void> openJobs(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('jobs-strip')));
    await tester.pumpAndSettle();
  }

  Future<void> chooseTranscribe(WidgetTester tester, int workId,
      {bool translate = false}) async {
    await tester.tap(find.byKey(Key('menu-$workId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(
        Key(translate ? 'translate-$workId' : 'transcribe-$workId')));
    await tester.pumpAndSettle();
  }

  testWidgets('consent states the bytes before ANY download, then the '
      'transcript lands on the work', (tester) async {
    final seeded = await seedEpisode();
    final store = FakeModelStore();
    final gate = RecordingForegroundGate();
    final services = testServices(tmp, modelStore: store, gate: gate);

    await openRiver(tester, services);
    await chooseTranscribe(tester, seeded.workId);

    // The chokepoint: dialog present, bytes named, metered warning, and
    // NOTHING has been downloaded yet.
    expect(find.byKey(const Key('consent-dialog')), findsOneWidget);
    expect(find.textContaining('43.5 MB'), findsOneWidget);
    expect(find.textContaining('metered'), findsOneWidget);
    expect(store.downloadsStarted, isEmpty,
        reason: 'consent comes BEFORE the wire');

    await tester.tap(find.byKey(const Key('consent-accept')));
    await tester.pumpAndSettle();

    // The whole pipeline ran: model fetched, transcript replaced the
    // placeholder segments, alignments carry word timings.
    expect(store.downloadsStarted, ['whisper-tiny-ggml']);
    final segments = await db.spineDao.segmentsOf(seeded.workId);
    expect([for (final s in segments) s.body],
        containsAll(['Ola mundo.', 'Tudo bem?']));
    expect(await db.spineDao.alignmentsOf(seeded.workId), isNotEmpty);
    expect(await db.jobsDao.unfinished(), isEmpty,
        reason: 'a finished job leaves no resumable row');
    expect(find.byKey(Key('job-card-${seeded.workId}')), findsNothing);

    // The foreground gate saw the whole lifecycle, progress included.
    expect(gate.events.first, startsWith('start:'));
    expect(gate.events.last, 'finished');
    expect(gate.events.where((e) => e.startsWith('progress:')), isNotEmpty);
  });

  testWidgets('declining the consent downloads nothing and starts nothing',
      (tester) async {
    final seeded = await seedEpisode();
    final store = FakeModelStore();
    final services = testServices(tmp, modelStore: store);

    await openRiver(tester, services);
    await chooseTranscribe(tester, seeded.workId);
    await tester.tap(find.byKey(const Key('consent-cancel')));
    await tester.pumpAndSettle();

    expect(store.downloadsStarted, isEmpty);
    expect(await db.jobsDao.unfinished(), isEmpty);
    expect(find.byKey(Key('job-card-${seeded.workId}')), findsNothing);
    final segments = await db.spineDao.segmentsOf(seeded.workId);
    expect(segments.single.body, 'Show notes.');
  });

  testWidgets('no dialog at all when model and audio are already local',
      (tester) async {
    final seeded = await seedEpisode();
    final store = FakeModelStore(downloadedIds: {'whisper-tiny-ggml'});
    final services = testServices(tmp, modelStore: store);
    services.audioFileFor(seeded.workId, enclosure)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('cached audio');

    await openRiver(tester, services);
    await chooseTranscribe(tester, seeded.workId);

    expect(find.byKey(const Key('consent-dialog')), findsNothing,
        reason: 'nothing would leave the device, so nothing is asked');
    final segments = await db.spineDao.segmentsOf(seeded.workId);
    expect([for (final s in segments) s.body],
        containsAll(['Ola mundo.', 'Tudo bem?']));
  });

  testWidgets(
      'transcribing (which downloads audio) clears a stale archived flag '
      '(P4 "archive, never forget")', (tester) async {
    final seeded = await seedEpisode();
    final store = FakeModelStore(downloadedIds: {'whisper-tiny-ggml'});
    final services = testServices(tmp, modelStore: store);
    // The audio was evicted earlier (keepLatestAudio) — no file on disk,
    // and the row remembers it.
    await db.feedsDao.setArchived(seeded.workId, 12345);

    await openRiver(tester, services);
    await chooseTranscribe(tester, seeded.workId);
    // Only the audio is missing (the model is already local), but that's
    // still a download — the consent chokepoint still fires.
    expect(find.byKey(const Key('consent-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('consent-accept')));
    await tester.pumpAndSettle();

    expect((await db.feedsDao.episodeOf(seeded.workId))!.archivedAtMs, isNull,
        reason: 'the audio is back on disk — the row should say so');
  });

  testWidgets('transcribe + translate writes an English mt layer over the '
      'same segments', (tester) async {
    final seeded = await seedEpisode(transcribed: true);
    final store = FakeModelStore(downloadedIds: {'whisper-tiny-ggml'});
    final services = testServices(tmp, modelStore: store);
    services.audioFileFor(seeded.workId, enclosure)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('cached audio');

    await openRiver(tester, services);
    await chooseTranscribe(tester, seeded.workId, translate: true);

    final en = await db.spineDao.layersOf(seeded.workId, lang: 'en');
    expect(en, isNotEmpty);
    expect(en.first.kind, 'mt');
    expect(await db.jobsDao.unfinished(), isEmpty);
  });

  testWidgets('Campaign 8 "Babel widens" Phase 4: whisper\'s own '
      'translate-while-transcribing lane (this file, pre-existing) and '
      'the Marian "Translate…" picker (Campaign 8, TranslationSentences) '
      'write to entirely separate artifacts for the SAME work — the '
      'artifact-separation law holds because they were never sharing a '
      'store to begin with, not because either was taught about the '
      'other', (tester) async {
    final seeded = await seedEpisode(transcribed: true);
    final store = FakeModelStore(downloadedIds: {'whisper-tiny-ggml'});
    final services = testServices(tmp, modelStore: store);
    services.audioFileFor(seeded.workId, enclosure)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('cached audio');

    await openRiver(tester, services);
    await chooseTranscribe(tester, seeded.workId, translate: true);

    // Whisper's own lane: an 'en' Layer row, kind 'mt', keyed by segment.
    final whisperMt = await db.spineDao.layersOf(seeded.workId, lang: 'en');
    expect(whisperMt, isNotEmpty);
    expect(whisperMt.first.kind, 'mt');

    // The SAME work, now also run through the Marian pipeline
    // (Campaign 8 Phase 1's TranslationSentences store) — a
    // completely different table, keyed by (workId, segmentIdx,
    // sentenceIdx, lang), that a user could plausibly reach separately
    // (open the reader, tap "Translate…") without either lane knowing
    // the other exists.
    final segments = await db.spineDao.segmentsOf(seeded.workId);
    await db.spineDao.upsertTranslationSentence(
        workId: seeded.workId,
        segmentIdx: segments.first.idx,
        sentenceIdx: 0,
        lang: 'en',
        sourceText: segments.first.body,
        body: 'Marian: ${segments.first.body}');
    await db.spineDao.setActiveTranslationLang(seeded.workId, 'en');

    // Neither write touched the other's artifact.
    final whisperMtAfter =
        await db.spineDao.layersOf(seeded.workId, lang: 'en');
    expect(whisperMtAfter.length, whisperMt.length,
        reason: 'the Marian write never touched the Layers table');
    final marian = await db.spineDao
        .translationSentencesOf(seeded.workId, lang: 'en');
    expect(marian.values.first.body,
        'Marian: ${segments.first.body}',
        reason: 'and the whisper write never touched TranslationSentences '
            '— confirmed by the "mt" kind check above never having seen '
            'this row either');
  });

  testWidgets('pause mid-download keeps a resumable card; resume finishes '
      'the job', (tester) async {
    final seeded = await seedEpisode();
    final store = FakeModelStore(beats: 12);
    final services = testServices(tmp, modelStore: store);

    await openRiver(tester, services);
    await chooseTranscribe(tester, seeded.workId);
    await tester.tap(find.byKey(const Key('consent-accept')));

    // Two beats in: Latest has one short line, telling the truth about
    // progress, and it is the way to the job's card.
    await tester.pump(const Duration(milliseconds: 250));
    final line = find.byKey(Key('job-line-${seeded.workId}'));
    expect(line, findsOneWidget);
    expect(find.byKey(Key('job-card-${seeded.workId}')), findsNothing);
    expect(find.textContaining('Getting the model'), findsOneWidget);
    expect(tester.getSize(line).height, lessThanOrEqualTo(48));

    await tester.tap(line);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(Key('job-card-${seeded.workId}')), findsOneWidget);

    await tester.tap(find.byKey(Key('job-pause-${seeded.workId}')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Paused'), findsOneWidget);
    expect(store.partial['whisper-tiny-ggml'], greaterThan(0),
        reason: 'cancel keeps the partial');
    final row = await db.jobsDao.load('transcribe-${seeded.workId}');
    expect(row!.state, JobState.cancelled);

    await tester.tap(find.byKey(Key('job-resume-${seeded.workId}')));
    // The restarted download is timer-paced (5 beats × 100ms) and the card
    // is deliberately calm — a determinate bar animates nothing — so
    // pumpAndSettle's frame-driven clock stops once the tap's ink ripple
    // fades. Drive the fake clock through the beats explicitly.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();

    final segments = await db.spineDao.segmentsOf(seeded.workId);
    expect([for (final s in segments) s.body],
        containsAll(['Ola mundo.', 'Tudo bem?']));
    expect(find.byKey(Key('job-card-${seeded.workId}')), findsNothing);
  });

  Future<void> seedJob(int workId,
      {required JobState state,
      String? checkpoint,
      int totalUnits = 0,
      int doneUnits = 0}) async {
    final jobId = 'transcribe-$workId';
    await db.jobsDao.save(Job(
        id: jobId,
        kind: 'transcribe',
        state: state,
        checkpoint: checkpoint,
        totalUnits: totalUnits,
        doneUnits: doneUnits,
        createdAtMs: 5));
    await db.jobsDao.setPayload(
        jobId,
        jsonEncode({
          'workId': workId,
          'title': 'Um episódio',
          'url': enclosure,
          'lang': null,
          'translate': false,
        }));
  }

  testWidgets('a job a kill interrupted picks itself back up on reopen, '
      'from its checkpoint, with no tap', (tester) async {
    final seeded = await seedEpisode();
    // A job orphaned by a process kill: row still "running".
    await seedJob(seeded.workId, state: JobState.running);

    final store = FakeModelStore(downloadedIds: {'whisper-tiny-ggml'});
    final services = testServices(tmp, modelStore: store);
    await openRiver(tester, services);
    await tester.pumpAndSettle();

    final segments = await db.spineDao.segmentsOf(seeded.workId);
    expect([for (final s in segments) s.body],
        containsAll(['Ola mundo.', 'Tudo bem?']));
    expect(find.byKey(Key('job-card-${seeded.workId}')), findsNothing);
    expect(await db.jobsDao.load('transcribe-${seeded.workId}'), isNull);
  });

  testWidgets('a job the user paused stays paused on reopen; Resume '
      'continues it', (tester) async {
    final seeded = await seedEpisode();
    await seedJob(seeded.workId, state: JobState.cancelled);

    final store = FakeModelStore(downloadedIds: {'whisper-tiny-ggml'});
    final services = testServices(tmp, modelStore: store);
    await openRiver(tester, services);
    await openJobs(tester);

    expect(find.byKey(Key('job-card-${seeded.workId}')), findsOneWidget);
    expect(find.textContaining('Paused'), findsOneWidget);
    expect(await db.spineDao.alignmentsOf(seeded.workId), isEmpty);

    await tester.tap(find.byKey(Key('job-resume-${seeded.workId}')));
    await tester.pumpAndSettle();

    final segments = await db.spineDao.segmentsOf(seeded.workId);
    expect([for (final s in segments) s.body],
        containsAll(['Ola mundo.', 'Tudo bem?']));
  });

  testWidgets('a failure says what went wrong, and remembers it',
      (tester) async {
    final seeded = await seedEpisode();
    final store = FakeModelStore(downloadedIds: {'whisper-tiny-ggml'});
    final services = testServices(tmp,
        modelStore: store,
        decoder: FakeDecoder(failWith: DecodeException('unknown codec')));
    services.audioFileFor(seeded.workId, enclosure)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);

    await openRiver(tester, services);
    await chooseTranscribe(tester, seeded.workId);
    await tester.pumpAndSettle();
    await openJobs(tester);

    expect(find.byKey(Key('job-status-${seeded.workId}')), findsOneWidget);
    expect(find.textContaining('couldn’t be read'), findsOneWidget);
    expect((await db.jobsDao.unfinished()).single.failureReason,
        contains('couldn’t be read'));
  });

  test('a transcript that lands with no reader open still binds earlier '
      'captures to their sentences', () async {
    final seeded = await seedEpisode();
    final captureId = await db.capturesDao.capture(
        profileId: seeded.profileId,
        workId: seeded.workId,
        positionMs: 500,
        nowMs: 1);
    final services = testServices(tmp,
        modelStore: FakeModelStore(downloadedIds: {'whisper-tiny-ggml'}));
    services.audioFileFor(seeded.workId, enclosure)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);
    final coordinator = TranscribeCoordinator(db: db, services: services);

    await coordinator.start(
        workId: seeded.workId,
        title: 'Um episódio',
        enclosureUrl: enclosure,
        translate: false);

    final capture = (await db.capturesDao.capturesOf(seeded.workId))
        .singleWhere((c) => c.id == captureId);
    expect(capture.segmentIdx, isNotNull);
  });

  group('the language each stage is locked to', () {
    Future<RecordingExecutor> run(int workId,
        {String? feedLang,
        String? workLang,
        String? detectedLang,
        bool translate = false}) async {
      if (feedLang != null) {
        final feed = (await db.feedsDao.feedById(
            (await db.feedsDao.episodeOf(workId))!.feedId))!;
        await db.feedsDao.updateRefreshState(feed.id,
            title: feed.title,
            etag: null,
            lastModified: null,
            breakerJson: '{}',
            language: feedLang,
            updateLanguage: true);
      }
      final executor = RecordingExecutor();
      final services = testServices(tmp,
          executor: executor,
          detectedLang: detectedLang,
          modelStore: FakeModelStore(downloadedIds: {'whisper-tiny-ggml'}));
      services.audioFileFor(workId, enclosure)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);
      await TranscribeCoordinator(db: db, services: services).start(
          workId: workId,
          title: 'Um episódio',
          enclosureUrl: enclosure,
          lang: workLang,
          translate: translate);
      return executor;
    }

    test('the feed\'s declared language, as whisper names it', () async {
      final seeded = await seedEpisode();
      final spec = (await run(seeded.workId, feedLang: 'pt-BR')).specs.single;
      expect(spec.lang, 'pt');
      expect(spec.langSource, 'feed');
    });

    test('the work\'s own language wins over the feed\'s', () async {
      final seeded = await seedEpisode();
      final spec = (await run(seeded.workId, feedLang: 'en-us', workLang: 'pt'))
          .specs
          .single;
      expect(spec.lang, 'pt');
      expect(spec.langSource, 'declared');
    });

    test('the feed\'s language labels the transcript but never becomes the '
        'work\'s own', () async {
      final seeded = await seedEpisode();
      final first = (await run(seeded.workId, feedLang: 'pt-BR')).specs.single;
      expect(first.lang, 'pt');
      expect((await db.spineDao.workById(seeded.workId))!.lang, isNull,
          reason: 'a feed tag is a guess about the show, not the episode');
      expect(
          (await db.spineDao.layersOf(seeded.workId, lang: 'pt')),
          isNotEmpty,
          reason: 'translate offers still need the label');

      // The publisher fixes its tag; the next run must follow it.
      final second = (await run(seeded.workId, feedLang: 'es')).specs.single;
      expect(second.lang, 'es');
      expect(second.langSource, 'feed');
      expect((await db.spineDao.workById(seeded.workId))!.lang, isNull);
    });

    test('a language the user declared is the work\'s from then on',
        () async {
      final seeded = await seedEpisode();
      await run(seeded.workId, workLang: 'pt');
      expect((await db.spineDao.workById(seeded.workId))!.lang, 'pt');
    });

    test('starting over a paused job keeps the language it was locked to',
        () async {
      final seeded = await seedEpisode();
      final jobId = 'transcribe-${seeded.workId}';
      await db.jobsDao.save(Job(
          id: jobId,
          kind: 'transcribe',
          state: JobState.cancelled,
          checkpoint: null,
          totalUnits: 0,
          doneUnits: 0,
          createdAtMs: 5));
      await db.jobsDao.setPayload(
          jobId,
          jsonEncode({
            'workId': seeded.workId,
            'title': 'Um episódio',
            'url': enclosure,
            'lang': 'pt',
            'langSource': 'feed',
            'translate': false,
          }));
      // The feed has since changed its tag; the half-done transcript is
      // already in the old language.
      final spec = (await run(seeded.workId, feedLang: 'es')).specs.single;
      expect(spec.lang, 'pt');
      expect(spec.langSource, 'feed');
    });

    test('a language whisper does not know falls back to detection',
        () async {
      final seeded = await seedEpisode();
      final spec = (await run(seeded.workId, feedLang: 'tlh')).specs.single;
      expect(spec.lang, isNull);
    });

    test('translate reuses the language transcription detected', () async {
      final seeded = await seedEpisode();
      final specs = (await run(seeded.workId,
              detectedLang: 'pt', translate: true))
          .specs;
      expect(specs.map((s) => s.task),
          [WhisperTask.transcribe, WhisperTask.translate]);
      expect(specs.first.lang, isNull);
      expect(specs.last.lang, 'pt');
      expect(specs.last.langSource, 'detected');
      expect((await db.spineDao.workById(seeded.workId))!.lang, isNull,
          reason: 'a detection is not a declaration: a wrong one must not '
              'lock every later run');
    });
  });

  test('a refused screen-off service is never released', () async {
    final seeded = await seedEpisode();
    final gate = ThrowingStartGate();
    final services = testServices(tmp,
        gate: gate,
        modelStore: FakeModelStore(downloadedIds: {'whisper-tiny-ggml'}));
    final coordinator = TranscribeCoordinator(db: db, services: services);

    await coordinator.start(
        workId: seeded.workId,
        title: 'Um episódio',
        enclosureUrl: enclosure,
        translate: false);

    expect(gate.events, isNot(contains('finished')));
  });

  testWidgets('Discard forgets the job and its rows', (tester) async {
    final seeded = await seedEpisode();
    final jobId = 'transcribe-${seeded.workId}';
    await db.jobsDao.save(Job(
        id: jobId,
        kind: 'transcribe',
        state: JobState.cancelled,
        checkpoint: '{"nextWindowStartMs":25000,"chunks":[]}',
        totalUnits: 3,
        doneUnits: 1,
        createdAtMs: 5));
    await db.jobsDao.setPayload(
        jobId,
        jsonEncode({
          'workId': seeded.workId,
          'title': 'Um episódio',
          'url': enclosure,
          'lang': null,
          'translate': false,
        }));

    await openRiver(tester, testServices(tmp));
    await openJobs(tester);
    expect(find.byKey(Key('job-card-${seeded.workId}')), findsOneWidget);

    await tester.tap(find.byKey(Key('job-dismiss-${seeded.workId}')));
    await tester.pumpAndSettle();

    expect(find.byKey(Key('job-card-${seeded.workId}')), findsNothing);
    expect(await db.jobsDao.load(jobId), isNull);
  });

  testWidgets('a job that stopped takes no room on Latest: it is counted '
      'in the jobs line, and Try again and Discard are on the Jobs page',
      (tester) async {
    final seeded = await seedEpisode();
    await seedJob(seeded.workId, state: JobState.failed);

    await openRiver(tester, testServices(tmp));

    expect(find.byKey(Key('job-card-${seeded.workId}')), findsNothing);
    expect(find.byKey(Key('job-line-${seeded.workId}')), findsNothing);
    expect(find.text('Try again'), findsNothing);
    expect(find.text('Discard'), findsNothing);
    expect(find.textContaining('1 didn’t finish'), findsOneWidget);

    await openJobs(tester);
    expect(find.byKey(Key('job-card-${seeded.workId}')), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Discard'), findsOneWidget);
  });

  testWidgets('the launch picks up the one-tap job that was written down, '
      'once every other job has been restored', (tester) async {
    final seeded = await seedEpisode(transcribed: true);
    await db.deviceSettingsDao.write(
        listenLineKey,
        jsonEncode([
          {'workId': seeded.workId, 'lang': 'es'},
        ]));

    await openRiver(tester, testServices(tmp));
    await tester.runAsync(() async {
      // This transcript has no text, so the job ends with a reason, and
      // the record going is what shows the launch ran it.
      for (var i = 0;
          i < 100 &&
              await db.deviceSettingsDao.read(listenLineKey) != null;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });

    expect(await db.deviceSettingsDao.read(listenLineKey), isNull);
  });

  group('the transcript appears as it is made', () {
    const one = ['Ola mundo.', 'Tudo bem?'];

    Future<(TranscribeCoordinator, List<List<String>>)> coordinatorFor(
        int workId,
        {void Function(TranscribeCoordinator c)? onEachWrite}) async {
      final services = testServices(tmp,
          modelStore: FakeModelStore(downloadedIds: {'whisper-tiny-ggml'}));
      services.audioFileFor(workId, enclosure)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);
      final seen = <List<String>>[];
      late TranscribeCoordinator coordinator;
      coordinator = TranscribeCoordinator(
          db: db,
          services: services,
          onTranscribed: (id) {}); // replaced below
      coordinator.onTranscribed = (id) {
        // Read synchronously enough: the write has landed when this fires.
        unawaited(() async {
          seen.add([
            for (final s in await db.spineDao.segmentsOf(id)) s.body
          ]);
        }());
        onEachWrite?.call(coordinator);
      };
      return (coordinator, seen);
    }

    test('each window\'s text is on the work before the job ends, and the '
        'card says how far it has got', () async {
      final seeded = await seedEpisode();
      final soFar = <int?>[];
      final jobsAlive = <bool>[];
      final (coordinator, seen) = await coordinatorFor(seeded.workId,
          onEachWrite: (c) {
        soFar.add(c.cards.isEmpty ? null : c.cards.single.soFarMs);
        jobsAlive.add(c.isActive(seeded.workId));
      });

      await coordinator.start(
          workId: seeded.workId,
          title: 'Um episódio',
          enclosureUrl: enclosure,
          translate: false);
      await pumpEventQueue();

      // 60 s is three windows: the text grows window by window, and each
      // write replaces rather than adds.
      expect(seen.take(3).toList(), [
        one,
        [...one, ...one],
        [...one, ...one, ...one],
      ]);
      expect(jobsAlive.first, isTrue,
          reason: 'the first window shows while the job still runs');
      expect(soFar.first, 2600);
      expect([for (final s in await db.spineDao.segmentsOf(seeded.workId))
            s.body], [...one, ...one, ...one]);
      expect(await db.jobsDao.unfinished(), isEmpty);
    });

    test('a pause leaves the transcript so far on the work; Resume finishes '
        'it without a sentence twice', () async {
      final seeded = await seedEpisode();
      var paused = false;
      final (coordinator, _) = await coordinatorFor(seeded.workId,
          onEachWrite: (c) {
        if (paused) return;
        paused = true;
        c.cancel(seeded.workId);
      });

      await coordinator.start(
          workId: seeded.workId,
          title: 'Um episódio',
          enclosureUrl: enclosure,
          translate: false);
      await pumpEventQueue();

      expect(coordinator.cards.single.phase, TranscribePhase.paused);
      final partial = [
        for (final s in await db.spineDao.segmentsOf(seeded.workId)) s.body
      ];
      expect(partial, isNotEmpty);
      expect(partial.length, lessThan(6));
      expect(await transcriptIsWhole(db, seeded.workId), isFalse,
          reason: 'a partial transcript is never taken for the episode');

      await coordinator.resume(seeded.workId);
      await pumpEventQueue();

      expect([for (final s in await db.spineDao.segmentsOf(seeded.workId))
            s.body], [...one, ...one, ...one]);
      expect(await transcriptIsWhole(db, seeded.workId), isTrue);
    });

    test('after a kill, the transcript so far is back on the work as the job '
        'picks itself up', () async {
      final seeded = await seedEpisode();
      // Killed after the first of three windows committed.
      await seedJob(seeded.workId,
          state: JobState.running,
          checkpoint: jsonEncode({
            'nextWindowStartMs': 25000,
            'chunks': [
              {'text': 'Ola mundo.', 't0': 0, 't1': 1500, 'words': null},
              {'text': 'Tudo bem?', 't0': 1500, 't1': 2600, 'words': null},
            ],
          }),
          totalUnits: 3,
          doneUnits: 1);
      final payload =
          jsonDecode(await db.jobsDao.payloadOf('transcribe-${seeded.workId}'))
              as Map<String, dynamic>;
      await db.jobsDao.setPayload('transcribe-${seeded.workId}',
          jsonEncode({...payload, 'soFar': true}));
      final (coordinator, seen) = await coordinatorFor(seeded.workId);

      await coordinator.restore();
      await coordinator.resumeInterrupted();
      await pumpEventQueue();

      expect(seen.first, one,
          reason: 'the committed window shows before any new one runs');
      expect([for (final s in await db.spineDao.segmentsOf(seeded.workId))
            s.body], [...one, ...one, ...one]);
    });

    test('a job over a transcript the work already has never shows part of '
        'one in its place', () async {
      final seeded = await seedEpisode(transcribed: true);
      final (coordinator, seen) = await coordinatorFor(seeded.workId);

      await coordinator.start(
          workId: seeded.workId,
          title: 'Um episódio',
          enclosureUrl: enclosure,
          translate: false);
      await pumpEventQueue();

      // One write, the finished transcript: the old one stood until then.
      expect(seen, [
        [...one, ...one, ...one]
      ]);
    });

    test('Discard takes the transcript so far away with the job', () async {
      final seeded = await seedEpisode();
      final (coordinator, _) = await coordinatorFor(seeded.workId,
          onEachWrite: (c) => c.cancel(seeded.workId));
      await coordinator.start(
          workId: seeded.workId,
          title: 'Um episódio',
          enclosureUrl: enclosure,
          translate: false);
      await pumpEventQueue();
      expect(await db.spineDao.alignmentsOf(seeded.workId), isNotEmpty);

      await coordinator.dismiss(seeded.workId);

      expect(await db.spineDao.alignmentsOf(seeded.workId), isEmpty);
      expect(await db.spineDao.segmentsOf(seeded.workId), isEmpty);
    });
  });
}
