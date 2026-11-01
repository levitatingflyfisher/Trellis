/// The transcript as it is made (owner, 21 Oct: "more streaming updates
/// rather than batch"): a transcription of an episode with no transcript
/// writes the text of every window as it lands, so Read shows what is
/// done so far. These say whether a work's transcript is whole or still
/// being made, and how far it has got, in words.
library;

import 'dart:convert';

import 'package:jobs_core/jobs_core.dart';

import '../../db/database.dart';
import 'transcribe_coordinator.dart' show transcribeJobId;

/// A transcript still being made: whether its job is running now (else it
/// is paused or stopped), and the end of the text so far.
typedef TranscriptMaking = ({bool running, int soFarMs});

/// How [workId]'s transcript stands while it is made; null when it is
/// whole, or when there is none being shown as it is made.
Future<TranscriptMaking?> transcriptMaking(AppDatabase db, int workId) async {
  final row = await db.jobsDao.load(transcribeJobId(workId));
  if (row == null || row.state == JobState.done) return null;
  try {
    final payload =
        jsonDecode(await db.jobsDao.payloadOf(row.id)) as Map<String, dynamic>;
    if (payload['soFar'] != true) return null;
  } catch (_) {
    return null;
  }
  final aligned = await db.spineDao.alignmentsOf(workId);
  if (aligned.isEmpty) return null;
  var end = 0;
  for (final a in aligned) {
    if (a.tEndMs > end) end = a.tEndMs;
  }
  return (running: row.state == JobState.running, soFarMs: end);
}

/// Whether [workId] has its whole transcript: what translating it, or
/// making it in another language, needs. Part of one is not enough.
Future<bool> transcriptIsWhole(AppDatabase db, int workId) async {
  if ((await db.spineDao.alignmentsOf(workId)).isEmpty) return false;
  return await transcriptMaking(db, workId) == null;
}

/// How much of the episode the transcript so far covers, in words:
/// "the first 12 minutes".
String soFarSpan(int soFarMs) {
  final minutes = soFarMs ~/ 60000;
  if (minutes < 1) return 'the start';
  return minutes == 1 ? 'the first minute' : 'the first $minutes minutes';
}

/// The line under a transcription's card while its text shows as it is
/// made.
String soFarCardLine(int soFarMs, {required bool working}) => working
    ? 'You can read ${soFarSpan(soFarMs)} now. More appears as it is made.'
    : 'You can read ${soFarSpan(soFarMs)} now.';

/// The line at the top of the reader over a transcript still being made.
String soFarReaderLine(TranscriptMaking making) => making.running
    ? 'Still transcribing: this is ${soFarSpan(making.soFarMs)}. More '
        'appears here as it is made.'
    : 'Transcribing stopped part way: this is ${soFarSpan(making.soFarMs)}. '
        'Resume it on the episode’s page.';
