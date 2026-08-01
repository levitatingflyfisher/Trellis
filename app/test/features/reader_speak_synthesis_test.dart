import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_screen.dart';
import 'package:trellis/features/reader/speech/speech_engine.dart';
import 'package:trellis/features/reader/speech/speech_temp_files.dart';

import '../support/fake_speech_audio_queue.dart';
import '../support/fake_synthesis_engine.dart';
import '../support/fake_tts.dart';

class _FakeTempFiles implements SpeechTempFiles {
  final List<(int, SynthResult)> writeCalls = [];
  final List<String> deleteCalls = [];
  int _n = 0;

  @override
  Future<String> write(int index, SynthResult result) async {
    writeCalls.add((index, result));
    return 'sentence-${_n++}.wav';
  }

  @override
  Future<void> delete(String path) async {
    deleteCalls.add(path);
  }
}

/// The REAL speak loop forked over a synthesis engine (ADR-0006, the final
/// pass): unlike reader_speak_test.dart (system voice only), these tests
/// inject a [FakeSynthesisSpeechEngine] + [FakeSpeechAudioQueue] and drive
/// [SpeechPlaybackPipeline] end to end through the reader, proving the
/// cursor law holds on the neural path exactly as it does on the system
/// voice's.
void main() {
  late AppDatabase db;
  late FakeTtsSpeaker tts;
  late FakeSynthesisSpeechEngine engine;
  late FakeSpeechAudioQueue queue;
  late _FakeTempFiles tempFiles;
  late int profileId;
  late int workId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tts = FakeTtsSpeaker();
    engine = FakeSynthesisSpeechEngine();
    queue = FakeSpeechAudioQueue();
    tempFiles = _FakeTempFiles();
    profileId = await db.profilesDao.create('Ada');
    workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'note',
        title: 'Fado',
        persistence: 'work',
        firstSeenEpochDay: 100,
        lang: 'pt');
    await db.spineDao.insertSegments(workId, const [
      (idx: 0, kind: 'prose', text: 'Ola mundo.'),
      (idx: 1, kind: 'prose', text: 'Tudo bem hoje.'),
      (idx: 2, kind: 'prose', text: 'Ate logo.'),
    ]);
  });
  tearDown(() => db.close());

  Future<void> pumpReader(WidgetTester tester,
      {Future<SynthesisSpeechEngine?> Function({String? lang})?
          resolveSpeechEngine,
      bool offerNeuralVoice = false,
      int? workOverride}) async {
    final work = (await db.spineDao.worksOf(profileId))
        .firstWhere((w) => w.id == (workOverride ?? workId));
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(
            db: db,
            profileId: profileId,
            work: work,
            tts: tts,
            offerNeuralVoice: offerNeuralVoice,
            resolveSpeechEngine: resolveSpeechEngine,
            createSpeechAudioQueue: () => queue,
            createSpeechTempFiles: () => tempFiles)));
    await tester.pumpAndSettle();
  }

  Future<Position?> savedPosition() =>
      db.spineDao.position(profileId: profileId, workId: workId);

  String rsvpWord(WidgetTester tester) {
    String at(Key k) => tester.widget<Text>(find.byKey(k)).data!;
    return at(const Key('rsvp-bef')) +
        at(const Key('rsvp-piv')) +
        at(const Key('rsvp-aft'));
  }

  group('the synthesis engine drives real playback', () {
    testWidgets(
        'sentence-start events from the queue advance the cursor and save '
        'Position exactly as the system voice does', (tester) async {
      await pumpReader(tester,
          resolveSpeechEngine: ({lang}) async => engine);

      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();

      // The whole 3-sentence work fits inside the default lookahead — all
      // three are requested up front (the "synthesize ahead" contract).
      expect(engine.calls.map((c) => c.text).toList(),
          ['Ola mundo.', 'Tudo bem hoje.', 'Ate logo.']);
      expect(engine.calls.every((c) => c.lang == 'pt'), isTrue);

      engine.complete(0);
      await tester.pump();
      queue.emitIndex(0);
      await tester.pump();
      // index 0 IS the sentence the cursor already sits on — no move yet,
      // mirroring "stopping mid-sentence leaves the row at that sentence's
      // start".
      expect(rsvpWord(tester), 'Ola');

      engine.complete(1);
      await tester.pump();
      queue.emitIndex(1);
      await tester.pump();
      expect(rsvpWord(tester), 'Tudo', reason: 'the cursor moved with speech');
      var pos = await savedPosition();
      expect((pos!.segmentIdx, pos.wordIdx), (1, 0));
      expect(pos.lastModality, 'speak');

      engine.complete(2);
      await tester.pump();
      queue.emitIndex(2);
      await tester.pump();
      pos = await savedPosition();
      expect((pos!.segmentIdx, pos.wordIdx), (2, 0));
    });

    testWidgets('stopping mid-sentence tears down the pipeline: the queue '
        'is cleared and every written temp file is deleted', (tester) async {
      await pumpReader(tester,
          resolveSpeechEngine: ({lang}) async => engine);
      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();
      engine.complete(0);
      await tester.pump();
      queue.emitIndex(0);
      await tester.pump();
      expect(tempFiles.writeCalls, isNotEmpty);

      await tester.tap(find.byKey(const Key('speak-toggle'))); // stop
      await tester.pump();
      // Cancelling the pipeline's own subscriptions on stop needs a real
      // event-loop turn that FakeAsync's simulated clock alone won't drive
      // (the same reason speech_playback_pipeline_test.dart's pure-Dart
      // tests use Future.delayed rather than a widget pump).
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();

      expect(queue.clearCalls, greaterThanOrEqualTo(1));
      expect(tempFiles.deleteCalls, isNotEmpty);
    });

    testWidgets('a run that plays to the end restores the non-speaking '
        'state through the same path the system voice uses', (tester) async {
      await pumpReader(tester,
          resolveSpeechEngine: ({lang}) async => engine);
      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();

      engine.complete(0);
      await tester.pump();
      queue.emitIndex(0);
      await tester.pump();
      engine.complete(1);
      await tester.pump();
      queue.emitIndex(1);
      await tester.pump();
      engine.complete(2);
      await tester.pump();
      queue.emitIndex(2);
      await tester.pump();

      expect(
          tester
              .widget<IconButton>(find.byKey(const Key('speak-toggle')))
              .isSelected,
          isTrue,
          reason: 'still speaking — the last clip has not finished playing');

      queue.emitCompleted(); // the queue finished playing everything
      await tester.pump();

      expect(
          tester
              .widget<IconButton>(find.byKey(const Key('speak-toggle')))
              .isSelected,
          isFalse);
      final pos = await savedPosition();
      expect(pos!.segmentIdx, 2);
      expect(pos.lastModality, 'speak');
    });

    testWidgets('stopping and restarting speech quickly runs a clean second '
        'run — the first run\'s stale synthesis result cannot move the '
        'cursor', (tester) async {
      await pumpReader(tester,
          resolveSpeechEngine: ({lang}) async => engine);
      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();
      final firstRunCalls = engine.calls.length;
      expect(firstRunCalls, greaterThan(0));

      await tester.tap(find.byKey(const Key('speak-toggle'))); // stop
      await tester.pump();
      // Cancelling the pipeline's own subscriptions on stop needs a real
      // event-loop turn that FakeAsync's simulated clock alone won't drive
      // (the same reason speech_playback_pipeline_test.dart's pure-Dart
      // tests use Future.delayed rather than a widget pump).
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.tap(find.byKey(const Key('speak-toggle'))); // start again
      await tester.pump();

      expect(engine.calls.length, greaterThan(firstRunCalls),
          reason: 'the second run issued its own synthesis calls');

      // The FIRST run's synthesis call resolving now is a straggler — the
      // pipeline's own generation fencing must swallow it.
      engine.complete(0);
      await tester.pump();
      expect(rsvpWord(tester), 'Ola', reason: 'nothing moved from the stale result');

      // The second run proceeds normally from its own calls.
      engine.complete(firstRunCalls);
      await tester.pump();
      queue.emitIndex(0);
      await tester.pump();
      expect(rsvpWord(tester), 'Ola',
          reason: 'index 0 of the NEW run is still its own starting sentence');
    });
  });

  group('the voice-absent case (no voice on disk) still runs the system '
      'voice', () {
    testWidgets('resolveSpeechEngine resolving to null falls back to the '
        'system voice, hint intact', (tester) async {
      await pumpReader(tester,
          resolveSpeechEngine: ({lang}) async => null, offerNeuralVoice: true);

      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();

      expect(find.textContaining('Models'), findsOneWidget);
      expect(tts.utterances, [(text: 'Ola mundo.', lang: 'pt')]);
      expect(engine.calls, isEmpty);
    });
  });

  group('the settings escape (ADR-0006): prefer the system voice on purpose',
      () {
    testWidgets('no control appears when there is no neural voice to '
        'escape from', (tester) async {
      await pumpReader(tester); // no resolveSpeechEngine at all

      await tester.tap(find.byKey(const Key('reader-overflow')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('voice-preference-toggle')), findsNothing);
    });

    testWidgets('a persisted preference for the system voice keeps speech '
        'off the neural engine even though one resolved', (tester) async {
      await db.profilesDao.setPreferSystemVoice(profileId, true);
      await pumpReader(tester,
          resolveSpeechEngine: ({lang}) async => engine);

      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();

      expect(tts.utterances, [(text: 'Ola mundo.', lang: 'pt')]);
      expect(engine.calls, isEmpty);
    });

    testWidgets('toggling the control from the overflow menu switches the '
        'NEXT run and persists the choice', (tester) async {
      await pumpReader(tester,
          resolveSpeechEngine: ({lang}) async => engine);

      await tester.tap(find.byKey(const Key('reader-overflow')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('voice-preference-toggle')), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-preference-toggle')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();

      expect(tts.utterances, isNotEmpty);
      expect(engine.calls, isEmpty,
          reason: 'the toggle sent this run to the system voice');
      expect(await db.profilesDao.preferSystemVoice(profileId), isTrue);
    });
  });

  group('sentinel segments (code/table/figure) — the two engines diverge on '
      'purpose', () {
    late int sentinelWorkId;

    setUp(() async {
      sentinelWorkId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'note',
          title: 'Com codigo',
          persistence: 'work',
          firstSeenEpochDay: 100,
          lang: 'en');
      await db.spineDao.insertSegments(sentinelWorkId, const [
        (idx: 0, kind: 'prose', text: 'Before the code.'),
        (idx: 1, kind: 'code', text: 'print(1)'),
        (idx: 2, kind: 'prose', text: 'After the code.'),
      ]);
    });

    testWidgets('the system voice still blips silently through the code '
        'segment (unchanged)', (tester) async {
      await pumpReader(tester, workOverride: sentinelWorkId);

      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();
      expect(tts.utterances, [(text: 'Before the code.', lang: 'en')]);

      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      // The code segment produced no utterance of its own — the loop
      // passed straight through it to the next prose segment.
      expect(tts.utterances, hasLength(2));
      expect(tts.utterances[1].text, 'After the code.');
    });

    testWidgets('the neural voice skips the code segment outright — never '
        'asked to synthesize it, no cursor stop there', (tester) async {
      await pumpReader(tester,
          workOverride: sentinelWorkId,
          resolveSpeechEngine: ({lang}) async => engine);

      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();

      expect(engine.calls.map((c) => c.text).toList(),
          ['Before the code.', 'After the code.']);
    });
  });
}
