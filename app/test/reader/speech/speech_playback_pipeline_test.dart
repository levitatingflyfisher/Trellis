import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/reader/speech/speech_engine.dart';
import 'package:trellis/features/reader/speech/speech_playback_pipeline.dart';
import 'package:trellis/features/reader/speech/speech_temp_files.dart';

import '../../support/fake_speech_audio_queue.dart';
import '../../support/fake_synthesis_engine.dart';

/// SpeechPlaybackPipeline: synthesizes a work's sentences AHEAD of
/// playback, writes each to a temp file, appends them in order to a
/// gapless [FakeSpeechAudioQueue], and drives sentence-start callbacks off
/// the queue's own index stream — never an app-side timer. Every test here
/// is pure async/await (Completers the test controls directly); no real
/// clock, no platform channel, no real disk.
class _FakeTempFiles implements SpeechTempFiles {
  final List<(int, SynthResult)> writeCalls = [];
  final List<String> deleteCalls = [];

  @override
  Future<String> write(int index, SynthResult result) async {
    writeCalls.add((index, result));
    return 'sentence-$index.wav';
  }

  @override
  Future<void> delete(String path) async {
    deleteCalls.add(path);
  }
}

void main() {
  late FakeSynthesisSpeechEngine engine;
  late FakeSpeechAudioQueue queue;
  late _FakeTempFiles tempFiles;
  late List<int> started;

  late List<int> doneCount;

  SpeechPlaybackPipeline buildPipeline({int lookahead = 2}) {
    return SpeechPlaybackPipeline(
      engine: engine,
      queue: queue,
      tempFiles: tempFiles,
      onSentenceStart: started.add,
      onDone: () => doneCount.add(1),
      lookahead: lookahead,
    );
  }

  setUp(() {
    engine = FakeSynthesisSpeechEngine();
    queue = FakeSpeechAudioQueue();
    tempFiles = _FakeTempFiles();
    started = [];
    doneCount = [];
  });

  test('kicks off synthesis lookahead sentences ahead of the one playing',
      () async {
    final pipeline = buildPipeline(lookahead: 2);
    await pipeline.start(['One.', 'Two.', 'Three.', 'Four.'], lang: 'en');

    // Sentences 0, 1, 2 are all in flight before sentence 0 has even
    // finished rendering — that's the "synthesize ahead" contract, and
    // nothing has been appended or played yet.
    expect(engine.calls.map((c) => c.text).toList(),
        ['One.', 'Two.', 'Three.']);
    expect(engine.calls.every((c) => c.lang == 'en'), isTrue);
    expect(queue.appended, isEmpty);
    expect(queue.playCalls, 0);
  });

  test('appends sentences in SENTENCE order even when later synth calls '
      'resolve first', () async {
    final pipeline = buildPipeline(lookahead: 2);
    await pipeline.start(['One.', 'Two.', 'Three.']);

    engine.complete(2); // resolves LAST sentence's synthesis first
    engine.complete(1);
    engine.complete(0); // the loop was blocked on this one
    await pipeline.done;

    expect(tempFiles.writeCalls.map((c) => c.$1).toList(), [0, 1, 2]);
    expect(queue.appended, ['sentence-0.wav', 'sentence-1.wav', 'sentence-2.wav']);
  });

  test('plays once the first sentence is queued, not before', () async {
    final pipeline = buildPipeline(lookahead: 2);
    await pipeline.start(['One.', 'Two.']);
    expect(queue.playCalls, 0);

    engine.complete(0);
    // Sentence 1 is still in flight, so `pipeline.done` won't resolve yet;
    // a single zero-duration delay is enough to drain every pending
    // microtask (Dart fully drains microtasks before any timer fires),
    // which is all the append/play chain needs.
    await Future<void>.delayed(Duration.zero);

    expect(queue.appended, contains('sentence-0.wav'));
    expect(queue.playCalls, 1);

    engine.complete(1);
    await pipeline.done;
    expect(queue.playCalls, 1, reason: 'play() is called once per run, not per sentence');
  });

  test('sentence-start callbacks come from the queue\'s own index stream, '
      'offset by startAt', () async {
    final pipeline = buildPipeline(lookahead: 0);
    await pipeline.start(['One.', 'Two.', 'Three.'], startAt: 1);

    // The fake's broadcast controller delivers asynchronously (matching a
    // real Stream), so each emission needs a microtask turn.
    queue.emitIndex(0); // the queue is relative to what WAS queued (from startAt)
    await Future<void>.delayed(Duration.zero);
    expect(started, [1]);
    queue.emitIndex(1);
    await Future<void>.delayed(Duration.zero);
    expect(started, [1, 2]);
  });

  test('stop() fences a late synthesis result — it never reaches the queue',
      () async {
    final pipeline = buildPipeline(lookahead: 0);
    await pipeline.start(['One.', 'Two.']);
    expect(engine.calls, hasLength(1));

    await pipeline.stop();
    engine.complete(0); // resolves AFTER stop — a straggler
    await Future<void>.delayed(Duration.zero);

    expect(tempFiles.writeCalls, isEmpty);
    expect(queue.appended, isEmpty);
    expect(started, isEmpty);
  });

  test('stop() deletes every temp file this run had already written',
      () async {
    final pipeline = buildPipeline(lookahead: 0);
    await pipeline.start(['One.', 'Two.']);
    engine.complete(0);
    await Future<void>.delayed(Duration.zero);
    expect(tempFiles.writeCalls, hasLength(1)); // sentence 0 written

    await pipeline.stop();
    expect(tempFiles.deleteCalls, ['sentence-0.wav']);
  });

  test('a starting a second run stops the first (only one run alive at a '
      'time)', () async {
    final pipeline = buildPipeline(lookahead: 0);
    await pipeline.start(['a.', 'b.']);
    await pipeline.start(['x.']); // supersedes the first run

    engine.complete(0); // the FIRST run's "a." call — must be fenced
    await Future<void>.delayed(Duration.zero);
    expect(tempFiles.writeCalls, isEmpty,
        reason: 'the superseded run\'s result must not land');

    engine.complete(1); // the SECOND run's "x." call
    await pipeline.done;
    // tempFiles indexes by the sentence's position WITHIN its own run
    // (0-based from that run's startAt), not by the engine's lifetime
    // call counter — the second run starts its own numbering at 0.
    expect(queue.appended, ['sentence-0.wav']);
  });

  test('a synthesis error stops the run cleanly without throwing', () async {
    final pipeline = buildPipeline(lookahead: 0);
    await pipeline.start(['One.', 'Two.']);
    engine.completeWithError(0, Exception('native init failed'));
    await pipeline.done; // must complete, not hang or rethrow into the zone

    expect(queue.appended, isEmpty);
    expect(tempFiles.writeCalls, isEmpty);
  });

  test('pause/resume delegate straight to the queue', () async {
    final pipeline = buildPipeline();
    await pipeline.pause();
    expect(queue.pauseCalls, 1);
    await pipeline.resume();
    expect(queue.resumeCalls, 1);
  });

  group('onDone (the "finished naturally" signal)', () {
    test('fires once every sentence is appended and the queue reports '
        'completed', () async {
      final pipeline = buildPipeline(lookahead: 0);
      await pipeline.start(['One.', 'Two.']);
      engine.complete(0);
      await Future<void>.delayed(Duration.zero);
      engine.complete(1);
      await pipeline.done;

      expect(doneCount, isEmpty, reason: 'the queue has not reported completed yet');
      queue.emitCompleted();
      await Future<void>.delayed(Duration.zero);
      expect(doneCount, [1]);
    });

    test('a completed event that arrives before the last sentence is even '
        'appended does NOT fire onDone — synthesis is just running behind '
        'playback, not actually finished', () async {
      final pipeline = buildPipeline(lookahead: 0);
      await pipeline.start(['One.', 'Two.']);
      engine.complete(0);
      await Future<void>.delayed(Duration.zero);
      // Sentence 1 is still mid-synthesis; the player has caught up to the
      // end of what's been appended and (mis)reports completed.
      queue.emitCompleted();
      await Future<void>.delayed(Duration.zero);
      expect(doneCount, isEmpty);

      engine.complete(1);
      await pipeline.done;
      queue.emitCompleted();
      await Future<void>.delayed(Duration.zero);
      expect(doneCount, [1], reason: 'the LATER, genuine completion still fires');
    });

    test('a completed event that arrives after stop() is discarded — the '
        'user already left, this run is over', () async {
      final pipeline = buildPipeline(lookahead: 0);
      await pipeline.start(['One.', 'Two.']);
      engine.complete(0);
      await Future<void>.delayed(Duration.zero);
      engine.complete(1);
      await pipeline.done; // every sentence appended — _reachedEnd is true

      await pipeline.stop();
      queue.emitCompleted(); // a straggler from the stopped run
      await Future<void>.delayed(Duration.zero);
      expect(doneCount, isEmpty);
    });

    test('stop() before the run reaches its last sentence leaves onDone '
        'silent even if a completed event slips through', () async {
      final pipeline = buildPipeline(lookahead: 0);
      await pipeline.start(['One.', 'Two.']);
      // Nothing synthesized yet — this run never reached its end.
      await pipeline.stop();
      queue.emitCompleted();
      await Future<void>.delayed(Duration.zero);
      expect(doneCount, isEmpty);
    });
  });
}
