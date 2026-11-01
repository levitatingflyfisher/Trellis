import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jobs_core/jobs_core.dart';
import 'package:loom_core/loom_core.dart' as core;
import 'package:ml_runtime/ml_runtime.dart';
import 'package:transcribe_core/transcribe_core.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_screen.dart';
import 'package:trellis/features/transcribe/transcribe_coordinator.dart';
import 'package:trellis/features/transcribe/transcript_writer.dart';

/// The reader over a transcript still being made (owner, 21 Oct: "more
/// streaming updates rather than batch"): it says how far the transcript
/// has got, and new text appears on the open page as each window lands,
/// without moving the reader's place.
void main() {
  late AppDatabase db;
  late int profileId;
  late Work work;

  TranscriptionResult so(List<String> sentences) => TranscriptionResult(
        lang: 'en',
        layerKind: core.LayerKind.transcript,
        segments: [
          for (var i = 0; i < sentences.length; i++)
            core.Segment(
                idx: i, kind: core.SegmentKind.prose, text: sentences[i])
        ],
        alignments: [
          for (var i = 0; i < sentences.length; i++)
            core.Alignment(
                segmentIdx: i, tStartMs: i * 61000, tEndMs: (i + 1) * 61000)
        ],
        layers: [
          for (var i = 0; i < sentences.length; i++)
            core.Layer(
                segmentIdx: i,
                lang: 'en',
                kind: core.LayerKind.transcript,
                text: sentences[i])
        ],
        mergedChunks: [
          for (var i = 0; i < sentences.length; i++)
            TranscriptChunk(
                text: sentences[i],
                tStartMs: i * 61000,
                tEndMs: (i + 1) * 61000)
        ],
      );

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Ep 1',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/1.mp3');
    await writeTranscript(
        db: db, workId: id, result: so(['First sentence.']));
    await db.jobsDao.save(Job(
        id: transcribeJobId(id),
        kind: 'transcribe',
        state: JobState.running,
        checkpoint: null,
        totalUnits: 9,
        doneUnits: 2,
        createdAtMs: 5));
    await db.jobsDao.setPayload(
        transcribeJobId(id), jsonEncode({'workId': id, 'soFar': true}));
    work = (await db.spineDao.workById(id))!;
  });
  tearDown(() => db.close());

  testWidgets('it says how far the transcript has got, and new text '
      'appears on the open page', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(
            db: db, profileId: profileId, work: work, openOnPage: true)));
    await tester.pumpAndSettle();

    expect(
        find.text('Still transcribing: this is the first minute. More '
            'appears here as it is made.'),
        findsOneWidget);
    // The page sets one word to a widget.
    expect(find.text('Second'), findsNothing);

    await tester.runAsync(() => writeTranscript(
        db: db,
        workId: work.id,
        result: so(['First sentence.', 'Second sentence.'])));
    await tester.pumpAndSettle();

    expect(find.text('Second'), findsOneWidget);
    expect(
        find.text('Still transcribing: this is the first 2 minutes. More '
            'appears here as it is made.'),
        findsOneWidget);

    // The job ends: the line goes, the transcript is whole.
    await tester.runAsync(() => db.jobsDao.deleteJob(transcribeJobId(work.id)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reader-so-far')), findsNothing);
  });
}
