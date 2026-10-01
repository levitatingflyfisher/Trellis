import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jobs_core/jobs_core.dart';
import 'package:backup_core/backup_core.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/backup/db_bridge.dart';
import 'package:trellis/features/jobs/job_center.dart';
import 'package:trellis/features/jobs/jobs_screen.dart';

import '../../support/fake_services.dart';

/// The one place every long job is listed: what it is doing, how far it
/// got, and what went wrong if it stopped, with the matching verb.
void main() {
  late AppDatabase db;
  late Directory dir;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    dir = Directory.systemTemp.createTempSync('trellis-jobs-screen');
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> seed(String id, String kind, JobState state,
      {String? reason}) async {
    await db.jobsDao.save(Job(
        id: id,
        kind: kind,
        state: state,
        checkpoint: null,
        totalUnits: 0,
        doneUnits: 0,
        createdAtMs: 1));
    await db.jobsDao.setPayload(
        id,
        jsonEncode({
          'workId': 7,
          'title': 'Episode seven',
          'url': 'https://cast.test/7.mp3',
        }));
    if (reason != null) await db.jobsDao.setFailureReason(id, reason);
  }

  Future<JobCenter> pumpScreen(WidgetTester tester, {FakeAudioFetcher? fetcher}) async {
    final center = JobCenter.forDevice(
        db, testServices(dir, audioFetcher: fetcher ?? FakeAudioFetcher()));
    addTearDown(center.dispose);
    await tester.runAsync(center.restoreAndResume);
    await tester.pumpWidget(MaterialApp(home: JobsScreen(jobs: center)));
    await tester.pumpAndSettle();
    return center;
  }

  testWidgets('nothing running says so, kindly', (tester) async {
    await pumpScreen(tester);
    expect(find.byKey(const Key('jobs-empty')), findsOneWidget);
  });

  testWidgets('a failed download shows why, and Try again finishes it',
      (tester) async {
    await seed('download-7', 'download', JobState.failed,
        reason: 'Couldn’t reach the server.');
    final fetcher = FakeAudioFetcher();
    await pumpScreen(tester, fetcher: fetcher);

    expect(find.textContaining('Couldn’t reach the server.'), findsOneWidget);
    expect(find.text('Episode seven'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('download-retry-7')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(fetcher.fetched, ['https://cast.test/7.mp3']);
    expect(find.byKey(const Key('jobs-empty')), findsOneWidget);
  });

  testWidgets('a paused transcription is listed with Resume', (tester) async {
    await seed('transcribe-7', 'transcribe', JobState.cancelled);
    await pumpScreen(tester);

    expect(find.byKey(const Key('job-card-7')), findsOneWidget);
    expect(find.byKey(const Key('job-resume-7')), findsOneWidget);
  });

  test('a backup restore stops running jobs and resumes none of them onto '
      'the restored works', () async {
    Future<int> worksUpTo7(AppDatabase d, String lastTitle) async {
      final profile = await d.profilesDao.create('Reader');
      var id = 0;
      for (var i = 1; i <= 7; i++) {
        id = await d.spineDao.insertWork(
            profileId: profile,
            kind: 'note',
            title: i == 7 ? lastTitle : 'Filler $i',
            persistence: 'work',
            firstSeenEpochDay: 1);
      }
      return id;
    }

    expect(await worksUpTo7(db, 'Episode seven'), 7);
    await seed('download-7', 'download', JobState.running);
    await seed('transcribe-7', 'transcribe', JobState.running);
    final fetcher = ControllableAudioFetcher();
    final services = testServices(dir,
        audioFetcher: fetcher,
        modelStore: FakeModelStore(downloadedIds: {'whisper-tiny-ggml'}));
    final part = File(
        '${services.audioFileFor(7, 'https://cast.test/7.mp3').path}.part')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);
    final center = JobCenter.forDevice(db, services);
    addTearDown(center.dispose);
    await center.restoreAndResume();
    await pumpEventQueue();
    expect(fetcher.fetched, hasLength(1), reason: 'the download resumed');

    await center.stopAll();
    final other = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(other.close);
    await worksUpTo7(other, 'A different note');
    await DbBridge(db).restoreFullReplace(RowPayload.decode(RowPayload.encode(
        await DbBridge(other).exportTables(),
        createdAt: DateTime.utc(2026, 10, 1))));
    await center.reload();
    await pumpEventQueue();

    expect(fetcher.fetched, hasLength(1), reason: 'nothing resumed');
    expect(await db.jobsDao.unfinished(), isEmpty);
    expect(await db.spineDao.alignmentsOf(7), isEmpty);
    expect(center.counts.total, 0);
    expect(part.existsSync(), isFalse,
        reason: 'old bytes must never be appended to a different work 7');
  });

  test('after a backup restore, jobs the new data lacks are forgotten',
      () async {
    await seed('download-7', 'download', JobState.cancelled);
    final center = JobCenter.forDevice(db, testServices(dir));
    addTearDown(center.dispose);
    await center.restoreAndResume();
    expect(center.counts.paused, 1);

    await db.jobsDao.deleteJob('download-7');
    await center.reload();

    expect(center.counts.total, 0);
  });

  test('the strip line counts in plain words', () {
    expect(jobsSummary(const JobCounts(running: 1)), '1 job working');
    expect(jobsSummary(const JobCounts(running: 2, paused: 1, failed: 1)),
        '2 jobs working · 1 paused · 1 didn’t finish');
  });
}
