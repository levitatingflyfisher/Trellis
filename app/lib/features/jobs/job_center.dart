/// Every long-running job on this device, in one place: episode downloads,
/// transcription and the DSP preprocess.
///
/// Owned once per app run, above any reader's shell. Jobs belong to the
/// household rather than to a reader, and a coordinator rebuilt on every
/// reader switch would start a second runner on a job the first one
/// still holds.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../db/database.dart';
import '../../services/device_services.dart';
import '../dsp/dsp_coordinator.dart';
import '../feeds/episode_download_coordinator.dart';
import '../transcribe/transcribe_coordinator.dart';

/// How many jobs are in each state, for the strip that opens the Jobs
/// screen.
class JobCounts {
  final int running;
  final int paused;
  final int failed;
  const JobCounts({this.running = 0, this.paused = 0, this.failed = 0});

  int get total => running + paused + failed;
}

/// The strip's one line. Counts first, in plain words, worst news last so
/// it's the part the eye lands on.
String jobsSummary(JobCounts c) {
  String n(int count, String one) =>
      count == 1 ? '1 $one' : '$count ${one}s';
  return [
    if (c.running > 0) '${n(c.running, 'job')} working',
    if (c.paused > 0) '${c.paused} paused',
    if (c.failed > 0) '${c.failed} didn’t finish',
  ].join(' · ');
}

class JobCenter extends ChangeNotifier {
  final TranscribeCoordinator transcribe;

  /// Null on the web tier, where no dart:io file can be written.
  final EpisodeDownloadCoordinator? downloads;
  final DspCoordinator? dsp;

  JobCenter({required this.transcribe, this.downloads, this.dsp}) {
    for (final c in _parts) {
      c.addListener(notifyListeners);
    }
  }

  factory JobCenter.forDevice(AppDatabase db, DeviceServices services) {
    final downloads = services.localMlAvailable
        ? EpisodeDownloadCoordinator(services: services, db: db)
        : null;
    return JobCenter(
      downloads: downloads,
      transcribe: TranscribeCoordinator(
          db: db, services: services, downloads: downloads),
      dsp: services.localMlAvailable
          ? DspCoordinator(db: db, services: services)
          : null,
    );
  }

  List<ChangeNotifier> get _parts =>
      [transcribe, ?downloads, ?dsp];

  /// Rebuild every job from its row, then let the ones a kill interrupted
  /// carry on. Downloads go first so a transcription waiting on the same
  /// episode joins that download instead of starting another.
  Future<void> restoreAndResume() async {
    await downloads?.restore();
    await transcribe.restore();
    await dsp?.restore();
    unawaited(downloads?.resumeInterrupted());
    unawaited(transcribe.resumeInterrupted());
  }

  /// Before a backup restore: pause every job and wait until none is
  /// still writing, so nothing lands on a work whose id is about to mean
  /// something else.
  Future<void> stopAll() async {
    await Future.wait([
      transcribe.stopAll(),
      if (downloads != null) downloads!.stopAll(),
      if (dsp != null) dsp!.stopAll(),
    ]);
  }

  /// After a backup restore: drop every job memory held (and its partial
  /// files) and read what the restored rows carry. Resumes nothing; a
  /// restored job was never started on this device.
  Future<void> reload() async {
    downloads?.discardAll();
    transcribe.discardAll();
    dsp?.discardAll();
    await downloads?.restore();
    await transcribe.restore();
    await dsp?.restore();
  }

  /// Downloads a transcription card already speaks for are not listed
  /// twice.
  List<({int workId, EpisodeDownloadState state})> get standaloneDownloads {
    final owned = {for (final c in transcribe.cards) c.workId};
    return [
      for (final e in downloads?.entries ?? const [])
        if (!owned.contains(e.workId)) e
    ];
  }

  JobCounts get counts {
    var running = 0, paused = 0, failed = 0;
    for (final c in transcribe.cards) {
      switch (c.phase) {
        case TranscribePhase.paused:
          paused++;
        case TranscribePhase.failed:
          failed++;
        default:
          running++;
      }
    }
    for (final e in standaloneDownloads) {
      if (e.state.failed) {
        failed++;
      } else if (e.state.paused) {
        paused++;
      } else {
        running++;
      }
    }
    for (final c in dsp?.cards ?? const <DspCardState>[]) {
      switch (c.phase) {
        case DspPhase.paused:
          paused++;
        case DspPhase.failed:
          failed++;
        case DspPhase.ineligible:
          break;
        default:
          running++;
      }
    }
    return JobCounts(running: running, paused: paused, failed: failed);
  }

  @override
  void dispose() {
    for (final c in _parts) {
      c.removeListener(notifyListeners);
      c.dispose();
    }
    super.dispose();
  }
}
