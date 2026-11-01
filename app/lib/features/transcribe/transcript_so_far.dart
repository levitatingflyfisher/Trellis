/// The transcript as it is made (owner, 21 Oct: "more streaming updates
/// rather than batch"): a transcription of an episode with no transcript
/// writes the text of every window as it lands, so Read shows what is
/// done so far. These say whether a work's transcript is whole or still
/// being made, and how far it has got, in words.
library;

import 'dart:convert';

import 'package:drift/drift.dart' show Variable;

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

/// Where a work's transcript stands, as a list or a menu needs it. Part
/// of one, made or stopped, is never [whole]: "Transcribe again" and
/// translating wait for that.
enum TranscriptStage { none, makingNow, stoppedPartWay, whole }

/// Every transcript still being made, by work: [transcriptMaking] for a
/// whole list in two queries, so a long list costs what a short one does.
Future<Map<int, TranscriptMaking>> transcriptsMaking(AppDatabase db) async {
  final running = <int, bool>{};
  for (final row in await db.jobsDao.unfinished()) {
    if (row.kind != 'transcribe') continue;
    final id = int.tryParse(row.id.substring(row.id.indexOf('-') + 1));
    if (id == null || row.id != transcribeJobId(id)) continue;
    try {
      final payload = jsonDecode(row.payloadJson) as Map<String, dynamic>;
      if (payload['soFar'] != true) continue;
    } catch (_) {
      continue;
    }
    running[id] = row.state == JobState.running.name;
  }
  if (running.isEmpty) return const {};
  final ids = running.keys.toList();
  final ends = await db.customSelect(
    'SELECT work_id, MAX(t_end_ms) AS end_ms FROM alignments '
    'WHERE work_id IN (${List.filled(ids.length, '?').join(', ')}) '
    'GROUP BY work_id',
    variables: [for (final id in ids) Variable.withInt(id)],
    readsFrom: {db.alignments},
  ).get();
  return {
    for (final r in ends)
      r.read<int>('work_id'): (
        running: running[r.read<int>('work_id')]!,
        soFarMs: r.read<int>('end_ms'),
      ),
  };
}

/// The row's marker for a work with a transcript: "Transcript" when it
/// is whole, and how far it has got while it is made ("Transcribing, 12
/// of 40 min") or since it stopped ("Part transcript, 12 of 40 min").
String transcriptMarkerLabel(TranscriptMaking? making, int? durationMs) {
  if (making == null) return 'Transcript';
  final lead = making.running ? 'Transcribing' : 'Part transcript';
  if (durationMs == null || durationMs <= 0) {
    return '$lead, ${making.soFarMs ~/ 60000} min so far';
  }
  return '$lead, ${soFarOfLength(making.soFarMs, durationMs)}';
}

/// How much of an episode of [durationMs] a transcript so far covers:
/// "12 of 40 min", or "12 min" when the length is unknown.
String soFarOfLength(int soFarMs, int? durationMs) {
  final done = soFarMs ~/ 60000;
  if (durationMs == null || durationMs <= 0) return '$done min';
  return '$done of ${(durationMs / 60000).round()} min';
}

/// Why Translate waits on a transcript still being made: translating
/// part of one would leave the rest untranslated as it lands.
String translateWaitsLine(TranscriptMaking making, int? durationMs) =>
    'Translate waits for the whole transcript: '
    '${soFarOfLength(making.soFarMs, durationMs)} is done.';
