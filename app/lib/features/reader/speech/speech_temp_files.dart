/// Where synthesized sentences live on disk while they're queued for
/// playback (ADR-0006). A narrow seam so [SpeechPlaybackPipeline] tests
/// never touch real disk — the real implementation writes a WAV per
/// sentence under the app support dir and deletes it on stop/dispose (and
/// sweeps anything stale left over from a killed session, on app start).
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'speech_engine.dart';
import 'wav.dart';

abstract class SpeechTempFiles {
  /// Writes [result] to disk and returns the path a [SpeechAudioQueue] can
  /// play it from. [index] is the sentence's position within its OWN run
  /// (0-based from that run's startAt) — informational for the filename,
  /// not a global identity; [DiskSpeechTempFiles] adds its own run-unique
  /// prefix so two runs' files never collide on disk.
  Future<String> write(int index, SynthResult result);

  Future<void> delete(String path);
}

/// The real thing: one WAV file per sentence under
/// `<supportDir>/speech-temp/`. Each pipeline run gets its own [runId]
/// (an incrementing counter is enough — uniqueness within one process
/// lifetime is all that's needed, since stop()/dispose() clean up before
/// the counter could wrap in any realistic session) so a stopped run's
/// straggling write can never collide with — or be mistaken for — the
/// next run's file of the same sentence index.
class DiskSpeechTempFiles implements SpeechTempFiles {
  final Directory dir;
  static int _runCounter = 0;
  final int _runId = _runCounter++;

  DiskSpeechTempFiles({required this.dir});

  @override
  Future<String> write(int index, SynthResult result) async {
    await dir.create(recursive: true);
    final path = p.join(dir.path, 'run$_runId-sentence$index.wav');
    await File(path).writeAsBytes(wavBytes(result.samples, result.sampleRate));
    return path;
  }

  @override
  Future<void> delete(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
}

/// Deletes every file left in [dir] — called once at app start (main.dart)
/// so a session that was killed mid-speech (no chance to run stop()/
/// dispose()) doesn't accumulate orphaned WAVs forever. Missing directories
/// are not an error: nothing to sweep is the common case.
Future<void> sweepStaleSpeechTempFiles(Directory dir) async {
  if (!await dir.exists()) return;
  await for (final entry in dir.list()) {
    if (entry is File) {
      try {
        await entry.delete();
      } catch (_) {
        // Best-effort: a file another process is mid-writing (shouldn't
        // happen at app start, but a locked file is not worth crashing
        // boot over) is left for the next sweep.
      }
    }
  }
}
