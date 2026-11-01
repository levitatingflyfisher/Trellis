import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jobs_core/jobs_core.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/transcribe/job_cards.dart';
import 'package:trellis/features/transcribe/transcribe_coordinator.dart';
import 'package:trellis/features/transcribe/transcript_so_far.dart';

import '../support/fake_services.dart';

/// The plain lines that say how far a transcript shown as it is made has
/// got: on the job's card, and how a reopened app knows it.
void main() {
  late AppDatabase db;
  late Directory tmp;
  late int workId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('trellis-so-far');
    final profileId = await db.profilesDao.create('Ada');
    workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Um episódio',
        persistence: 'ephemeron',
        firstSeenEpochDay: 1,
        sourceUrl: 'https://cast.test/1.mp3');
  });
  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<void> seedPartial({required JobState state, bool soFar = true}) async {
    await db.spineDao.insertSegments(
        workId, const [(idx: 0, kind: 'prose', text: 'Ola mundo.')]);
    await db.spineDao.insertAlignments(
        workId, const [(segmentIdx: 0, tStartMs: 0, tEndMs: 754000)]);
    await db.jobsDao.save(Job(
        id: transcribeJobId(workId),
        kind: 'transcribe',
        state: state,
        checkpoint: null,
        totalUnits: 120,
        doneUnits: 31,
        createdAtMs: 5));
    await db.jobsDao.setPayload(
        transcribeJobId(workId),
        jsonEncode({
          'workId': workId,
          'title': 'Um episódio',
          'url': 'https://cast.test/1.mp3',
          'soFar': soFar,
        }));
  }

  test('the span is said in whole minutes, from the start', () {
    expect(soFarSpan(20000), 'the start');
    expect(soFarSpan(61000), 'the first minute');
    expect(soFarSpan(754000), 'the first 12 minutes');
  });

  test('a paused transcription shown as it is made is part of one; its '
      'reader line says so plainly', () async {
    await seedPartial(state: JobState.cancelled);
    final making = (await transcriptMaking(db, workId))!;
    expect(making.running, isFalse);
    expect(making.soFarMs, 754000);
    expect(await transcriptIsWhole(db, workId), isFalse);
    expect(soFarReaderLine(making),
        'Transcribing stopped part way: this is the first 12 minutes. '
        'Resume it on the episode’s page.');
    expect(soFarReaderLine((running: true, soFarMs: 754000)),
        'Still transcribing: this is the first 12 minutes. More appears '
        'here as it is made.');
  });

  test('a job over an old transcript leaves it whole', () async {
    await seedPartial(state: JobState.cancelled, soFar: false);
    expect(await transcriptMaking(db, workId), isNull);
    expect(await transcriptIsWhole(db, workId), isTrue);
  });

  testWidgets('a reopened app\'s card says how much can be read already',
      (tester) async {
    await tester.runAsync(() => seedPartial(state: JobState.cancelled));
    final coordinator =
        TranscribeCoordinator(db: db, services: testServices(tmp));
    await tester.runAsync(coordinator.restore);
    expect(coordinator.cards.single.soFarMs, 754000);

    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: TranscribeJobCards(coordinator: coordinator))));
    // Paused: what is there can be read, and nothing more is coming yet.
    expect(find.text('You can read the first 12 minutes now.'),
        findsOneWidget);
    expect(soFarCardLine(754000, working: true),
        'You can read the first 12 minutes now. More appears as it is made.');
  });
}
