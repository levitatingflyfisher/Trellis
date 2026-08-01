import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_screen.dart';

import '../support/fake_speech_audio_queue.dart';
import '../support/fake_synthesis_engine.dart';
import '../support/fake_tts.dart';

/// Speak-in-Spanish (ADR-0008 "Babel" Phase 4): the speak loop substitutes
/// each STORED translated sentence for the neural or system voice while
/// the reading cursor keeps advancing through the ORIGINAL sentences — the
/// karaoke cursor law is unchanged; only what is heard differs. A sentence
/// with no stored translation still speaks, in English, from the original.
void main() {
  late AppDatabase db;
  late FakeTtsSpeaker tts;
  late FakeSynthesisSpeechEngine synthEngine;
  late FakeSpeechAudioQueue queue;
  late int profileId;
  late int workId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tts = FakeTtsSpeaker();
    synthEngine = FakeSynthesisSpeechEngine();
    queue = FakeSpeechAudioQueue();
    profileId = await db.profilesDao.create('Ada');
    workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'article',
        title: 'A Story',
        persistence: 'work',
        firstSeenEpochDay: 100,
        lang: 'en');
    await db.spineDao.insertSegments(workId, const [
      (idx: 0, kind: 'prose', text: 'Hello there. How are you?'),
      (idx: 1, kind: 'prose', text: 'Goodbye now.'),
    ]);
    // Only the first and third sentences are translated — the second is
    // deliberately left untranslated to exercise the per-sentence fallback.
    await db.spineDao.upsertTranslationSentence(
        workId: workId,
        segmentIdx: 0,
        sentenceIdx: 0,
        lang: 'es',
        sourceText: 'Hello there.',
        body: 'Hola.');
    await db.spineDao.upsertTranslationSentence(
        workId: workId,
        segmentIdx: 1,
        sentenceIdx: 0,
        lang: 'es',
        sourceText: 'Goodbye now.',
        body: 'Adios.');
    await db.spineDao.setShowTranslationLayer(workId, true);
  });
  tearDown(() => db.close());

  Future<void> pumpReader(WidgetTester tester,
      {bool withSynthEngine = false}) async {
    final work =
        (await db.spineDao.worksOf(profileId)).firstWhere((w) => w.id == workId);
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(
            db: db,
            profileId: profileId,
            work: work,
            tts: tts,
            resolveSpeechEngine:
                withSynthEngine ? ({lang}) async => synthEngine : null,
            createSpeechAudioQueue: () => queue)));
    await tester.pumpAndSettle();
  }

  Future<void> openOverflow(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('reader-overflow')));
    await tester.pumpAndSettle();
  }

  group('the menu control', () {
    testWidgets('absent when Show Spanish is off', (tester) async {
      await db.spineDao.setShowTranslationLayer(workId, false);
      await pumpReader(tester);
      await openOverflow(tester);
      expect(find.byKey(const Key('speak-spanish-toggle')), findsNothing);
    });

    testWidgets('present once Show Spanish is on', (tester) async {
      await pumpReader(tester);
      await openOverflow(tester);
      expect(find.byKey(const Key('speak-spanish-toggle')), findsOneWidget);
    });
  });

  group('the system voice path', () {
    testWidgets('a translated sentence speaks Spanish; the untranslated '
        'one falls back to English; the cursor advances through the '
        'ORIGINAL sentences either way', (tester) async {
      await pumpReader(tester);
      await openOverflow(tester);
      await tester.tap(find.byKey(const Key('speak-spanish-toggle')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();
      expect(tts.utterances, [(text: 'Hola.', lang: 'es')]);

      // First sentence's 100ms beat completes → cursor moves to sentence 2
      // ("How are you?", untranslated) and speaks it in English.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(tts.utterances[1], (text: 'How are you?', lang: 'en'));

      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(tts.utterances[2], (text: 'Adios.', lang: 'es'));

      final pos = await db.spineDao.position(profileId: profileId, workId: workId);
      // The saved cursor is the ORIGINAL segment/word — never touched by
      // which language was actually spoken.
      expect(pos!.segmentIdx, 1);
      expect(pos.wordIdx, 0);
    });

    testWidgets('turning Speak in Spanish off mid-session (before starting) '
        'speaks English as usual', (tester) async {
      await pumpReader(tester);
      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();
      expect(tts.utterances, [(text: 'Hello there.', lang: 'en')]);
    });
  });

  group('the neural voice path', () {
    testWidgets('the pipeline receives Spanish text for translated '
        'sentences and English for the fallback, each correctly tagged; '
        'the cursor still advances through original word positions',
        (tester) async {
      await pumpReader(tester, withSynthEngine: true);
      await openOverflow(tester);
      await tester.tap(find.byKey(const Key('speak-spanish-toggle')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();

      expect(synthEngine.calls.map((c) => c.text).toList(),
          ['Hola.', 'How are you?', 'Adios.']);
      expect(synthEngine.calls.map((c) => c.lang).toList(),
          ['es', 'en', 'es']);

      synthEngine.complete(0);
      await tester.pump();
      queue.emitIndex(0);
      await tester.pump();
      // index 0 is the cursor's own starting sentence — no move yet.

      synthEngine.complete(1);
      await tester.pump();
      queue.emitIndex(1);
      await tester.pump();
      final pos = await db.spineDao.position(profileId: profileId, workId: workId);
      // Sentence 2's ORIGINAL position: segment 0, the second sentence's
      // first word ("How").
      expect(pos!.segmentIdx, 0);
    });
  });

  group('turning Show Spanish off resets Speak in Spanish', () {
    testWidgets('the toggle is off and hidden again after Show Spanish '
        'is turned off, and speech reverts to English', (tester) async {
      await pumpReader(tester);
      await openOverflow(tester);
      await tester.tap(find.byKey(const Key('speak-spanish-toggle')));
      await tester.pumpAndSettle();

      await openOverflow(tester);
      await tester.tap(find.byKey(const Key('show-spanish-toggle')));
      await tester.pumpAndSettle();

      await openOverflow(tester);
      expect(find.byKey(const Key('speak-spanish-toggle')), findsNothing);
      // Dismiss the still-open menu (nothing was tapped inside it — the
      // check above was a plain inspection) before reaching the AppBar
      // underneath it.
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();
      expect(tts.utterances, [(text: 'Hello there.', lang: 'en')]);
    });
  });
}
