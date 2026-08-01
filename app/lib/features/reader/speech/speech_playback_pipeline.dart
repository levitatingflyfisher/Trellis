/// Drives a [SynthesisSpeechEngine] through a work's sentences, gaplessly
/// (ADR-0006 — the fix for the platform TTS long-utterance stall):
/// synthesizes AHEAD of playback (default lookahead: 2 sentences), writes
/// each result to a temp file, and appends them in order to a
/// [SpeechAudioQueue] — the same player machinery the podcast player
/// already uses, never a second audio engine.
///
/// Sentence-start callbacks fire off the QUEUE's own index-change events,
/// never an app-side timer: the queue holds exactly one clip per sentence,
/// so an index change IS a sentence boundary, and this can't drift from
/// what's actually audible the way a computed timer could.
///
/// Generation fencing (mirrors reader_screen's `_speakGen`): every `start()`
/// bumps the generation, and any synthesis result that resolves after a
/// `stop()`/superseding `start()` is discarded rather than reaching the
/// queue — the exact shape of the existing `_speakGen` law, one level
/// lower in the stack.
library;

import 'dart:async';

import 'speech_audio_queue.dart';
import 'speech_engine.dart';
import 'speech_temp_files.dart';

class SpeechPlaybackPipeline {
  final SynthesisSpeechEngine engine;
  final SpeechAudioQueue queue;
  final SpeechTempFiles tempFiles;
  final void Function(int globalSentenceIndex) onSentenceStart;

  /// Fires once, when the run ends NATURALLY — every sentence synthesized,
  /// appended, and played through to the end — as opposed to being
  /// stopped/superseded or failing on a synthesis error. Mirrors
  /// `PlayerController`'s use of `EpisodePlayer.completedStream`: the
  /// reader restores its non-speaking state through the same path either
  /// way, but only a natural end should fire it.
  final void Function()? onDone;
  final int lookahead;

  int _gen = 0;
  StreamSubscription<int>? _indexSub;
  StreamSubscription<void>? _completedSub;

  /// Set once THIS run's synthesis loop has appended its last sentence —
  /// the fact [SpeechAudioQueue.completedStream] alone cannot see (it
  /// cannot distinguish "nothing more is coming" from "playback merely
  /// caught up to the synthesis lookahead buffer"). Only once this is true
  /// does a completed event get to mean anything.
  bool _reachedEnd = false;
  final List<String> _liveFiles = [];
  Future<void> _done = Future.value();

  SpeechPlaybackPipeline({
    required this.engine,
    required this.queue,
    required this.tempFiles,
    required this.onSentenceStart,
    this.onDone,
    this.lookahead = 2,
  });

  /// Completes when the current run finishes — every sentence queued, the
  /// run was stopped/superseded, or a synthesis call failed. Tests use
  /// this to await a run deterministically; the reader itself does not
  /// need to await it (speech is fire-and-forget, like `_speakLoop`).
  Future<void> get done => _done;

  /// Starts speaking [sentences] from index [startAt] (so a resumed
  /// position skips sentences already heard). Supersedes any run already
  /// in flight — starting a new run stops the old one.
  Future<void> start(List<String> sentences, {int startAt = 0, String? lang}) async {
    await _reset();
    final gen = _gen;
    if (sentences.isEmpty || startAt >= sentences.length) return;

    _indexSub = queue.currentIndexStream.listen((queueIndex) {
      if (gen != _gen) return;
      final globalIndex = startAt + queueIndex;
      if (globalIndex < sentences.length) onSentenceStart(globalIndex);
    });
    _completedSub = queue.completedStream.listen((_) {
      if (gen != _gen) return;
      if (!_reachedEnd) return; // playback caught up to synthesis — not done
      onDone?.call();
    });

    final runDone = Completer<void>();
    _done = runDone.future;
    unawaited(_synthesizeLoop(sentences, startAt, gen, lang, runDone));
  }

  Future<void> _synthesizeLoop(List<String> sentences, int startAt, int gen,
      String? lang, Completer<void> runDone) async {
    final inFlight = <int, Future<SynthResult>>{};
    Future<SynthResult> futureFor(int i) => inFlight.putIfAbsent(
        i, () => engine.synthesize(sentences[i], lang: lang));

    try {
      for (var i = startAt; i < sentences.length; i++) {
        if (gen != _gen) return;
        for (var j = i; j <= i + lookahead && j < sentences.length; j++) {
          futureFor(j);
        }

        final SynthResult result;
        try {
          result = await futureFor(i);
        } catch (_) {
          // Honest failure: stop this run cleanly rather than wedge the
          // queue on a sentence that will never arrive. The typed-error
          // surface to the reader's speak-mode door is Phase 2's concern
          // (SupertonicSpeechEngine, ADR-0007); the pipeline's job is just
          // to not hang.
          return;
        }
        if (gen != _gen) return;

        final path = await tempFiles.write(i - startAt, result);
        if (gen != _gen) {
          unawaited(tempFiles.delete(path));
          return;
        }
        _liveFiles.add(path);
        await queue.append(path);
        if (gen != _gen) return;

        if (i == startAt) await queue.play();
      }
      // The for-loop exhausted every sentence without being fenced out —
      // this run genuinely has nothing left to append. From here on a
      // completedStream event means the run is actually over.
      if (gen == _gen) _reachedEnd = true;
    } finally {
      if (!runDone.isCompleted) runDone.complete();
    }
  }

  Future<void> pause() => queue.pause();
  Future<void> resume() => queue.resume();

  /// Stops the current run: cancels the index listener, clears the queue,
  /// and deletes every temp file this run had already written. A
  /// synthesis call still in flight is left to resolve on its own — the
  /// generation check discards its result when it does.
  Future<void> stop() => _reset();

  /// Releases the pipeline's own resources. Does NOT dispose [engine] or
  /// [queue] — both are owned (and may be shared/reused) by the caller;
  /// disposing the voice engine on switch, or the audio queue on reader
  /// teardown, is the caller's call, not this pipeline's.
  Future<void> dispose() => _reset();

  Future<void> _reset() async {
    _gen++;
    _reachedEnd = false;
    await _indexSub?.cancel();
    _indexSub = null;
    await _completedSub?.cancel();
    _completedSub = null;
    await queue.clear();
    final files = List<String>.of(_liveFiles);
    _liveFiles.clear();
    for (final f in files) {
      unawaited(tempFiles.delete(f));
    }
  }
}
