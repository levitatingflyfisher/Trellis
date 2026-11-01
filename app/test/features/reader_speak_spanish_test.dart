import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_screen.dart';

import '../support/fake_speech_audio_queue.dart';
import '../support/fake_synthesis_engine.dart';
import '../support/fake_tts.dart';

/// Reading the translation aloud under Both (ADR-0008 "Babel" Phase 4;
/// generalized to any active translation target by Campaign 8 "Babel
/// widens" Phase 1; since 1.5.9 each sentence, then its stored
/// translation, rather than the translation in its place, which is what
/// Translation only does — reader_speak_translation_test.dart): the
/// reading cursor keeps advancing through the ORIGINAL sentences — the
/// karaoke cursor law is unchanged; only what is heard differs. A
/// sentence with no stored translation is read once, in English. This file keeps Spanish as its running example (the
/// shipped, most-covered pair) and adds one German-specific group to cover
/// the engine-selection fix Campaign 8 found: when no downloaded voice
/// speaks German (the engine's `speaks` leaves it out), Speak-in-German
/// must force the system voice even when a neural voice is primed and
/// preferred.
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

    testWidgets('present, on, labeled with the active language, once Show '
        '⟨language⟩ is on', (tester) async {
      await db.spineDao.setShowTranslationLayer(workId, true);
      await pumpReader(tester);
      await openOverflow(tester);
      expect(find.byKey(const Key('speak-translation-toggle')), findsOneWidget);
      expect(find.text('Read the Spanish aloud too'), findsOneWidget);
      expect(
          tester
              .widget<CheckedPopupMenuItem<String>>(
                  find.byKey(const Key('speak-translation-toggle')))
              .checked,
          isTrue);
    });
  });

  /// Reads one Both run on the system voice, one 100ms beat per
  /// utterance, and checks what was heard and where the cursor was left.
  Future<void> expectBothRun(WidgetTester tester,
      {required String lang,
      required String first,
      required String last}) async {
    await tester.tap(find.byKey(const Key('speak-toggle')));
    await tester.pump();
    await tester.pump();
    for (var k = 0; k < 4; k++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      await tester.pump();
    }
    expect(tts.utterances, [
      (text: 'Hello there.', lang: 'en'),
      (text: first, lang: lang),
      // Untranslated: read once, in English.
      (text: 'How are you?', lang: 'en'),
      (text: 'Goodbye now.', lang: 'en'),
      (text: last, lang: lang),
    ]);
    // The saved cursor is the ORIGINAL segment/word — never touched by
    // which language was actually spoken.
    final pos =
        await db.spineDao.position(profileId: profileId, workId: workId);
    expect(pos!.segmentIdx, 1);
    expect(pos.wordIdx, 0);
  }

  group('the system voice path', () {
    testWidgets('each sentence, then its Spanish; the untranslated one is '
        'read once in English; the cursor advances through the ORIGINAL '
        'sentences either way', (tester) async {
      await db.spineDao.setShowTranslationLayer(workId, true);
      await pumpReader(tester);
      await expectBothRun(tester, lang: 'es', first: 'Hola.', last: 'Adios.');
    });

    testWidgets('turning Read the ⟨language⟩ aloud too off (before '
        'starting) reads the original only', (tester) async {
      await db.spineDao.setShowTranslationLayer(workId, true);
      await pumpReader(tester);
      await openOverflow(tester);
      await tester.tap(find.byKey(const Key('speak-translation-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(tts.utterances, [
        (text: 'Hello there.', lang: 'en'),
        (text: 'How are you?', lang: 'en'),
      ]);
    });
  });

  group('the neural voice path', () {
    testWidgets('the pipeline receives each sentence then its Spanish, each '
        'correctly tagged; the cursor still advances through original word '
        'positions, holding on a sentence while its translation plays',
        (tester) async {
      await db.spineDao.setShowTranslationLayer(workId, true);
      await pumpReader(tester, withSynthEngine: true);

      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();

      // Two sentences of lookahead past the one about to play.
      expect(synthEngine.calls.map((c) => (c.text, c.lang)).toList(), [
        ('Hello there.', 'en'),
        ('Hola.', 'es'),
        ('How are you?', 'en'),
      ]);

      synthEngine.complete(0);
      await tester.pump();
      queue.emitIndex(0);
      await tester.pump();
      // index 0 is the cursor's own starting sentence — no move yet.

      synthEngine.complete(1);
      await tester.pump();
      queue.emitIndex(1);
      await tester.pump();
      var pos = await db.spineDao.position(profileId: profileId, workId: workId);
      // "Hola." is heard under its original: the place is still "Hello".
      expect((pos!.segmentIdx, pos.wordIdx), (0, 0));

      synthEngine.complete(2);
      await tester.pump();
      queue.emitIndex(2);
      await tester.pump();
      pos = await db.spineDao.position(profileId: profileId, workId: workId);
      // Sentence 2's ORIGINAL position: segment 0, the second sentence's
      // first word ("How").
      expect((pos!.segmentIdx, pos.wordIdx), (0, 2));
    });
  });

  group('turning Show ⟨language⟩ off reads the original only', () {
    testWidgets('the toggle is hidden after Show ⟨language⟩ is turned off, '
        'and speech is English only', (tester) async {
      await db.spineDao.setShowTranslationLayer(workId, true);
      await pumpReader(tester);

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
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(tts.utterances, [
        (text: 'Hello there.', lang: 'en'),
        (text: 'How are you?', lang: 'en'),
      ]);
    });
  });

  Future<void> translateTo(String lang, String first, String last) async {
    await db.spineDao.setActiveTranslationLang(workId, lang);
    await db.spineDao.upsertTranslationSentence(
        workId: workId,
        segmentIdx: 0,
        sentenceIdx: 0,
        lang: lang,
        sourceText: 'Hello there.',
        body: first);
    await db.spineDao.upsertTranslationSentence(
        workId: workId,
        segmentIdx: 1,
        sentenceIdx: 0,
        lang: lang,
        sourceText: 'Goodbye now.',
        body: last);
    await db.spineDao.setShowTranslationLayer(workId, true);
  }

  group('Campaign 8 "Babel widens": the engine-gating fix', () {
    // German, with no German voice downloaded: the fake engine speaks
    // English, Spanish, French and Portuguese only.
    setUp(() => translateTo('de', 'Hallo.', 'Auf Wiedersehen.'));

    testWidgets('reading German forces the SYSTEM voice for the whole run '
        'even when a neural voice is primed and preferred — never reaches '
        'the engine\'s own language gate at all', (tester) async {
      await pumpReader(tester, withSynthEngine: true);
      await openOverflow(tester);
      expect(find.text('Read the German aloud too'), findsOneWidget);
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      // The system voice spoke — the neural engine's fake never saw a
      // single call, proving the engine-SELECTION happened before any
      // per-utterance language tag could reach the engine's own gate
      // (which would have thrown, uncaught, had this run reached it).
      expect(synthEngine.calls, isEmpty);
      expect(tts.utterances, [
        (text: 'Hello there.', lang: 'en'),
        (text: 'Hallo.', lang: 'de'),
      ]);
    });

    testWidgets('Read the German aloud too OFF (still showing German text, '
        'just not reading it) still uses the neural voice normally — the '
        'gating is specific to a run that reads German, not a blanket '
        'refusal of the neural voice for a German translation',
        (tester) async {
      await pumpReader(tester, withSynthEngine: true);
      await openOverflow(tester);
      await tester.tap(find.byKey(const Key('speak-translation-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();

      expect(synthEngine.calls, isNotEmpty,
          reason: 'no translation read -> the neural voice speaks the '
              'original English text normally');
      expect(tts.utterances, isEmpty);
    });
  });

  group('Campaign 8 "Babel widens" Phase 2: per-script-family speak tests '
      '— the full fallback+cursor loop, one non-es test per script family '
      '(Latin already covered above by the German gating group; this adds '
      'the SAME 3-sentence shape "the system voice path" proves for '
      'Spanish, so German gets the identical assurance, plus Cyrillic and '
      'CJK)', () {
    testWidgets('Latin (German): each sentence then its German; the '
        'untranslated one is read once in English; the cursor advances '
        'through the ORIGINAL sentences either way', (tester) async {
      await translateTo('de', 'Hallo.', 'Auf Wiedersehen.');
      await pumpReader(tester);
      await expectBothRun(tester,
          lang: 'de', first: 'Hallo.', last: 'Auf Wiedersehen.');
    });

    testWidgets('Cyrillic (Russian): each sentence then its Russian; the '
        'untranslated one is read once in English; the cursor advances '
        'through the ORIGINAL sentences either way', (tester) async {
      await translateTo('ru', 'Привет.', 'До свидания.');
      await pumpReader(tester);
      await expectBothRun(tester,
          lang: 'ru', first: 'Привет.', last: 'До свидания.');
    });

    testWidgets('CJK (Chinese): each sentence then its Chinese; the '
        'untranslated one is read once in English; the cursor advances '
        'through the ORIGINAL sentences either way — the ORIGINAL text '
        'stays plain-English ASCII (en->X direction: splitSentences never '
        'runs over the translated CJK body, only over the English '
        'source), so this needs no CJK sentence-boundary handling — that '
        'is a Phase 3 concern for CJK-SOURCED works, not this direction',
        (tester) async {
      await translateTo('zh', '你好。', '再见。');
      await pumpReader(tester);
      await expectBothRun(tester, lang: 'zh', first: '你好。', last: '再见。');
    });

    for (final (lang, first) in const [('ru', 'Привет.'), ('zh', '你好。')]) {
      testWidgets('$lang is gated the SAME way German is: reading it '
          'forces the system voice even with a neural voice primed and '
          'preferred: no downloaded voice speaks it', (tester) async {
        await translateTo(lang, first, 'x');
        await pumpReader(tester, withSynthEngine: true);

        await tester.tap(find.byKey(const Key('speak-toggle')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump();

        expect(synthEngine.calls, isEmpty,
            reason: 'the neural engine fake never saw a call — engine '
                'SELECTION happened before any per-utterance language tag '
                'could reach the engine\'s own gate (which would have '
                'thrown, uncaught, had this run reached it)');
        expect(tts.utterances,
            [(text: 'Hello there.', lang: 'en'), (text: first, lang: lang)]);
      });
    }
  });
}
