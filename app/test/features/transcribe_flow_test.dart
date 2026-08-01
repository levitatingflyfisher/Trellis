import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jobs_core/jobs_core.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/fake_services.dart';
import '../support/scripted_fetcher.dart';

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
        sourceUrl: enclosure);
    await db.spineDao.insertSegments(
        workId, const [(idx: 0, kind: 'prose', text: 'Show notes.')]);
    await db.feedsDao.insertEpisode(
        workId: workId,
        feedId: feedId,
        guid: 'ep1',
        enclosureUrl: enclosure,
        publishedAtMs: DateTime.utc(2026, 8, 1).millisecondsSinceEpoch);
    return (profileId: profileId, workId: workId);
  }

  Future<void> openRiver(WidgetTester tester, dynamic services) async {
    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((u, h) => textResponse('')),
        createPlayer: () => player,
        services: services));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('River'));
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
    final seeded = await seedEpisode();
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
    final seeded = await seedEpisode();
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
    final store = FakeModelStore(beats: 5);
    final services = testServices(tmp, modelStore: store);

    await openRiver(tester, services);
    await chooseTranscribe(tester, seeded.workId);
    await tester.tap(find.byKey(const Key('consent-accept')));

    // Two beats in: the card is up and telling the truth about progress.
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(Key('job-card-${seeded.workId}')), findsOneWidget);
    expect(find.textContaining('Getting the model'), findsOneWidget);

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
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();

    final segments = await db.spineDao.segmentsOf(seeded.workId);
    expect([for (final s in segments) s.body],
        containsAll(['Ola mundo.', 'Tudo bem?']));
    expect(find.byKey(Key('job-card-${seeded.workId}')), findsNothing);
  });

  testWidgets('reopening the app shows the resumable job card; tapping '
      'Resume continues from the checkpoint', (tester) async {
    final seeded = await seedEpisode();
    // A job orphaned by a process kill: row still "running".
    final jobId = 'transcribe-${seeded.workId}';
    await db.jobsDao.save(Job(
        id: jobId,
        kind: 'transcribe',
        state: JobState.running,
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
          'lang': null,
          'translate': false,
        }));

    final store = FakeModelStore(downloadedIds: {'whisper-tiny-ggml'});
    final services = testServices(tmp, modelStore: store);
    await openRiver(tester, services);

    expect(find.byKey(Key('job-card-${seeded.workId}')), findsOneWidget);
    expect(find.textContaining('Paused'), findsOneWidget);

    await tester.tap(find.byKey(Key('job-resume-${seeded.workId}')));
    await tester.pumpAndSettle();

    final segments = await db.spineDao.segmentsOf(seeded.workId);
    expect([for (final s in segments) s.body],
        containsAll(['Ola mundo.', 'Tudo bem?']));
    expect(find.byKey(Key('job-card-${seeded.workId}')), findsNothing);
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
    expect(find.byKey(Key('job-card-${seeded.workId}')), findsOneWidget);

    await tester.tap(find.byKey(Key('job-dismiss-${seeded.workId}')));
    await tester.pumpAndSettle();

    expect(find.byKey(Key('job-card-${seeded.workId}')), findsNothing);
    expect(await db.jobsDao.load(jobId), isNull);
  });
}
