import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_screen.dart';

import '../support/fake_speech_audio_queue.dart';
import '../support/fake_synthesis_engine.dart';
import '../support/fake_tts.dart';

/// Speak-in-⟨language⟩ (ADR-0008 "Babel" Phase 4; generalized to any active
/// translation target by Campaign 8 "Babel widens" Phase 1): the speak loop
/// substitutes each STORED translated sentence for the neural or system
/// voice while the reading cursor keeps advancing through the ORIGINAL
/// sentences — the karaoke cursor law is unchanged; only what is heard
/// differs. A sentence with no stored translation still speaks, in English,
/// from the original. This file keeps Spanish as its running example (the
/// shipped, most-covered pair) and adds one German-specific group to cover
/// the engine-selection fix Campaign 8 found: Supertonic's own language
/// gate (`supertonicSupportedLangs`) does not cover German, so Speak-in-
/// German must force the system voice even when a neural voice is primed
/// and preferred.
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
    await db.spineDao.setActiveTranslationLang(workId, 'es');
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
    testWidgets('absent when Show ⟨language⟩ is off', (tester) async {
      await db.spineDao.setShowTranslationLayer(workId, false);
      await pumpReader(tester);
      await openOverflow(tester);
      expect(find.byKey(const Key('speak-translation-toggle')), findsNothing);
    });

    testWidgets('present, labeled with the active language, once Show '
        '⟨language⟩ is on', (tester) async {
      await db.spineDao.setShowTranslationLayer(workId, true);
      await pumpReader(tester);
      await openOverflow(tester);
      expect(find.byKey(const Key('speak-translation-toggle')), findsOneWidget);
      expect(find.text('Speak in Spanish'), findsOneWidget);
    });
  });

  group('the system voice path', () {
    testWidgets('a translated sentence speaks Spanish; the untranslated '
        'one falls back to English; the cursor advances through the '
        'ORIGINAL sentences either way', (tester) async {
      await db.spineDao.setShowTranslationLayer(workId, true);
      await pumpReader(tester);
      await openOverflow(tester);
      await tester.tap(find.byKey(const Key('speak-translation-toggle')));
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

    testWidgets('turning Speak in ⟨language⟩ off mid-session (before '
        'starting) speaks English as usual', (tester) async {
      await db.spineDao.setShowTranslationLayer(workId, true);
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
      await db.spineDao.setShowTranslationLayer(workId, true);
      await pumpReader(tester, withSynthEngine: true);
      await openOverflow(tester);
      await tester.tap(find.byKey(const Key('speak-translation-toggle')));
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

  group('turning Show ⟨language⟩ off resets Speak in ⟨language⟩', () {
    testWidgets('the toggle is off and hidden again after Show '
        '⟨language⟩ is turned off, and speech reverts to English',
        (tester) async {
      await db.spineDao.setShowTranslationLayer(workId, true);
      await pumpReader(tester);
      await openOverflow(tester);
      await tester.tap(find.byKey(const Key('speak-translation-toggle')));
      await tester.pumpAndSettle();

      await openOverflow(tester);
      await tester.tap(find.byKey(const Key('show-translation-toggle')));
      await tester.pumpAndSettle();

      await openOverflow(tester);
      expect(find.byKey(const Key('speak-translation-toggle')), findsNothing);
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

  group('Campaign 8 "Babel widens": the Supertonic engine-gating fix', () {
    setUp(() async {
      // Re-point the active layer at German — a language Supertonic's
      // own `supertonicSupportedLangs` does not cover (verified,
      // docs/reference/tts-voices.md).
      await db.spineDao.setActiveTranslationLang(workId, 'de');
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: 'de',
          sourceText: 'Hello there.',
          body: 'Hallo.');
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 1,
          sentenceIdx: 0,
          lang: 'de',
          sourceText: 'Goodbye now.',
          body: 'Auf Wiedersehen.');
      await db.spineDao.setShowTranslationLayer(workId, true);
    });

    testWidgets('Speak in German forces the SYSTEM voice even when a '
        'neural voice is primed and preferred — never reaches '
        'Supertonic\'s own language gate at all', (tester) async {
      await pumpReader(tester, withSynthEngine: true);
      await openOverflow(tester);
      expect(find.text('Speak in German'), findsOneWidget);
      await tester.tap(find.byKey(const Key('speak-translation-toggle')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();

      // The system voice spoke — the neural engine's fake never saw a
      // single call, proving the engine-SELECTION happened before any
      // per-utterance language tag could reach Supertonic's own gate
      // (which would have thrown SupertonicUnsupportedLangException,
      // uncaught, had this run reached it).
      expect(synthEngine.calls, isEmpty);
      expect(tts.utterances, [(text: 'Hallo.', lang: 'de')]);
    });

    testWidgets('Speak in German OFF (still showing German text, just '
        'not speaking it) still uses the neural voice normally — the '
        'gating fix is specific to the ACTIVE speak-substitution, not a '
        'blanket refusal of the neural voice for a German-source work',
        (tester) async {
      await pumpReader(tester, withSynthEngine: true);
      // Speak-in-German never toggled on — Show German is on (from
      // setUp), but that only affects DISPLAY, not speech.
      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();

      expect(synthEngine.calls, isNotEmpty,
          reason: 'no translation substitution requested -> the neural '
              'voice speaks the original English text normally');
      expect(tts.utterances, isEmpty);
    });
  });

  group('Campaign 8 "Babel widens" Phase 2: per-script-family speak tests '
      '— the full fallback+cursor loop, one non-es test per script family '
      '(Latin already covered above by the German gating group; this adds '
      'the SAME 3-sentence shape "the system voice path" proves for '
      'Spanish, so German gets the identical assurance, plus Cyrillic and '
      'CJK)', () {
    testWidgets('Latin (German): a translated sentence speaks German; the '
        'untranslated one falls back to English; the cursor advances '
        'through the ORIGINAL sentences either way', (tester) async {
      await db.spineDao.setActiveTranslationLang(workId, 'de');
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: 'de',
          sourceText: 'Hello there.',
          body: 'Hallo.');
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 1,
          sentenceIdx: 0,
          lang: 'de',
          sourceText: 'Goodbye now.',
          body: 'Auf Wiedersehen.');
      await db.spineDao.setShowTranslationLayer(workId, true);
      await pumpReader(tester);
      await openOverflow(tester);
      await tester.tap(find.byKey(const Key('speak-translation-toggle')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();
      expect(tts.utterances, [(text: 'Hallo.', lang: 'de')]);

      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(tts.utterances[1], (text: 'How are you?', lang: 'en'));

      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(tts.utterances[2], (text: 'Auf Wiedersehen.', lang: 'de'));

      final pos =
          await db.spineDao.position(profileId: profileId, workId: workId);
      expect(pos!.segmentIdx, 1);
      expect(pos.wordIdx, 0);
    });

    testWidgets('Cyrillic (Russian): a translated sentence speaks Russian; '
        'the untranslated one falls back to English; the cursor advances '
        'through the ORIGINAL sentences either way', (tester) async {
      await db.spineDao.setActiveTranslationLang(workId, 'ru');
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: 'ru',
          sourceText: 'Hello there.',
          body: 'Привет.');
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 1,
          sentenceIdx: 0,
          lang: 'ru',
          sourceText: 'Goodbye now.',
          body: 'До свидания.');
      await db.spineDao.setShowTranslationLayer(workId, true);
      await pumpReader(tester);
      await openOverflow(tester);
      await tester.tap(find.byKey(const Key('speak-translation-toggle')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();
      expect(tts.utterances, [(text: 'Привет.', lang: 'ru')]);

      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(tts.utterances[1], (text: 'How are you?', lang: 'en'));

      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(tts.utterances[2], (text: 'До свидания.', lang: 'ru'));

      final pos =
          await db.spineDao.position(profileId: profileId, workId: workId);
      expect(pos!.segmentIdx, 1);
      expect(pos.wordIdx, 0);
    });

    testWidgets('CJK (Chinese): a translated sentence speaks Chinese; the '
        'untranslated one falls back to English; the cursor advances '
        'through the ORIGINAL sentences either way — the ORIGINAL text '
        'stays plain-English ASCII (en->X direction: splitSentences never '
        'runs over the translated CJK body, only over the English '
        'source), so this needs no CJK sentence-boundary handling — that '
        'is a Phase 3 concern for CJK-SOURCED works, not this direction',
        (tester) async {
      await db.spineDao.setActiveTranslationLang(workId, 'zh');
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: 'zh',
          sourceText: 'Hello there.',
          body: '你好。');
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 1,
          sentenceIdx: 0,
          lang: 'zh',
          sourceText: 'Goodbye now.',
          body: '再见。');
      await db.spineDao.setShowTranslationLayer(workId, true);
      await pumpReader(tester);
      await openOverflow(tester);
      await tester.tap(find.byKey(const Key('speak-translation-toggle')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();
      expect(tts.utterances, [(text: '你好。', lang: 'zh')]);

      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(tts.utterances[1], (text: 'How are you?', lang: 'en'));

      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(tts.utterances[2], (text: '再见。', lang: 'zh'));

      final pos =
          await db.spineDao.position(profileId: profileId, workId: workId);
      expect(pos!.segmentIdx, 1);
      expect(pos.wordIdx, 0);
    });

    testWidgets('Cyrillic (Russian) is gated the SAME way German is: '
        'Speak in Russian forces the system voice even with a neural '
        'voice primed and preferred — Cyrillic is not in Supertonic\'s '
        'own `supertonicSupportedLangs` ({en, es}, Phase 0)', (tester) async {
      await db.spineDao.setActiveTranslationLang(workId, 'ru');
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: 'ru',
          sourceText: 'Hello there.',
          body: 'Привет.');
      await db.spineDao.setShowTranslationLayer(workId, true);
      await pumpReader(tester, withSynthEngine: true);
      await openOverflow(tester);
      await tester.tap(find.byKey(const Key('speak-translation-toggle')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();

      expect(synthEngine.calls, isEmpty,
          reason: 'the neural engine fake never saw a call — engine '
              'SELECTION happened before any per-utterance language tag '
              'could reach Supertonic\'s own gate (which would have '
              'thrown SupertonicUnsupportedLangException, uncaught, had '
              'this run reached it)');
      expect(tts.utterances, [(text: 'Привет.', lang: 'ru')]);
    });

    testWidgets('CJK (Chinese) is gated the SAME way German is: Speak in '
        'Chinese forces the system voice even with a neural voice primed '
        'and preferred — CJK is not in Supertonic\'s own '
        '`supertonicSupportedLangs` ({en, es}, Phase 0)', (tester) async {
      await db.spineDao.setActiveTranslationLang(workId, 'zh');
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: 'zh',
          sourceText: 'Hello there.',
          body: '你好。');
      await db.spineDao.setShowTranslationLayer(workId, true);
      await pumpReader(tester, withSynthEngine: true);
      await openOverflow(tester);
      await tester.tap(find.byKey(const Key('speak-translation-toggle')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();

      expect(synthEngine.calls, isEmpty,
          reason: 'the neural engine fake never saw a call — engine '
              'SELECTION happened before any per-utterance language tag '
              'could reach Supertonic\'s own gate (which would have '
              'thrown SupertonicUnsupportedLangException, uncaught, had '
              'this run reached it)');
      expect(tts.utterances, [(text: '你好。', lang: 'zh')]);
    });
  });
}
