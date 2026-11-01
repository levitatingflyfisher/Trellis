import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_prefs.dart';
import 'package:trellis/features/reader/reader_screen.dart';
import 'package:trellis/features/reader/speech/read_aloud_voices.dart';
import 'package:trellis/features/reader/translation/translation_service.dart';
import 'package:trellis/features/reader/translation/translator.dart';
import 'package:trellis/services/device_services.dart';

import '../support/fake_speech_audio_queue.dart';
import '../support/fake_synthesis_engine.dart';
import '../support/fake_translation_service.dart';
import '../support/fake_tts.dart';

/// 1.5.9 (user: "I can transcribe a podcast and translate it to Russian,
/// but I can't get the Russian text to speech"): Read aloud reads the
/// translation the page shows. Translation only reads the translation;
/// Both reads each sentence and then its translation, each in a voice
/// for its own language. The downloaded voice has no Russian, so Russian
/// goes to the phone's voices; a phone with no Russian voice says so
/// instead of reading Russian with an English voice, or reading nothing.
void main() {
  late AppDatabase db;
  late FakeTtsSpeaker tts;
  late FakeSynthesisSpeechEngine synthEngine;
  late FakeSpeechAudioQueue queue;
  late int profileId;
  late int workId;

  const enVoice = SystemVoice(name: 'en-us-x-iol-local', locale: 'en-US');
  const ruVoiceA = SystemVoice(name: 'ru-ru-x-ruc-local', locale: 'ru-RU');
  const ruVoiceB = SystemVoice(name: 'ru-ru-x-rud-local', locale: 'ru-RU');
  const ruNetwork = SystemVoice(
      name: 'ru-ru-x-ruc-network', locale: 'ru-RU', needsInternet: true);

  Future<void> addTranslation(String lang, List<String> bodies) async {
    const sources = [
      (0, 0, 'Hello there.'),
      (0, 1, 'How are you?'),
      (1, 0, 'Goodbye now.'),
    ];
    for (var k = 0; k < sources.length; k++) {
      final (seg, i, src) = sources[k];
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: seg,
          sentenceIdx: i,
          lang: lang,
          sourceText: src,
          body: bodies[k]);
    }
    await db.spineDao.setActiveTranslationLang(workId, lang);
    await db.spineDao.setShowTranslationLayer(workId, true);
  }

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tts = FakeTtsSpeaker(installed: [enVoice, ruVoiceA, ruVoiceB]);
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
    await addTranslation('ru', const ['Привет.', 'Как дела?', 'До свидания.']);
  });
  tearDown(() => db.close());

  Future<void> pumpReader(WidgetTester tester,
      {bool withSynthEngine = false,
      bool speakTranslation = false,
      TranslationService? translation,
      int? id}) async {
    final work = (await db.spineDao.workById(id ?? workId))!;
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(
            db: db,
            profileId: profileId,
            work: work,
            tts: tts,
            speakTranslation: speakTranslation,
            translation: translation,
            resolveSpeechEngine:
                withSynthEngine ? ({lang}) async => synthEngine : null,
            createSpeechAudioQueue: () => queue)));
    await tester.pumpAndSettle();
  }

  /// Opens on Page (Follow along), where Both shows each translation
  /// under its sentence; a text's Play there is Read aloud.
  Future<void> onPage() => db.profilesDao.updateReaderPrefs(profileId,
      (p) => p.copyWith(session: const ReaderSession(mode: 'scroll')));

  Future<void> readAloud(WidgetTester tester) async {
    final onPage = find.byKey(const Key('reader-play'));
    await tester.tap(onPage.evaluate().isNotEmpty
        ? onPage
        : find.byKey(const Key('speak-toggle')));
    await tester.pump();
    await tester.pump();
  }

  Future<void> nextUtterance(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    await tester.pump();
  }

  Future<void> openVoices(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('reader-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('read-aloud-voices')));
    await tester.pumpAndSettle();
  }

  bool translationLit(WidgetTester tester, String key) => find
      .ancestor(
          of: find.byKey(Key(key)),
          matching: find.byKey(const Key('translation-lit')))
      .evaluate()
      .isNotEmpty;

  testWidgets('Translation only reads translated sentences in the '
      'translation language', (tester) async {
    await db.spineDao.setTranslationOnly(workId, true);
    await pumpReader(tester, withSynthEngine: true);
    await readAloud(tester);

    expect(tts.utterances, [(text: 'Привет.', lang: 'ru')]);
    // The downloaded voice has no Russian: it is never handed any.
    expect(synthEngine.calls, isEmpty);

    await nextUtterance(tester);
    expect(tts.utterances.last, (text: 'Как дела?', lang: 'ru'));
    // The page follows the voice: the place is the original's second
    // sentence ("How", word 2), the one being heard in Russian.
    final pos =
        await db.spineDao.position(profileId: profileId, workId: workId);
    expect((pos!.segmentIdx, pos.wordIdx), (0, 2));

    await nextUtterance(tester);
    expect(tts.utterances.last, (text: 'До свидания.', lang: 'ru'));
  });

  testWidgets('Both reads source then translation, each with its own '
      'language\'s voice', (tester) async {
    await onPage();
    await pumpReader(tester, withSynthEngine: true);
    await readAloud(tester);
    expect(tts.utterances, [(text: 'Hello there.', lang: 'en')]);
    expect(translationLit(tester, 'translation-0-0'), isFalse);

    await nextUtterance(tester);
    expect(tts.utterances.last, (text: 'Привет.', lang: 'ru'));
    // The highlight moves to the translation while it is heard.
    expect(translationLit(tester, 'translation-0-0'), isTrue);

    await nextUtterance(tester);
    expect(tts.utterances.last, (text: 'How are you?', lang: 'en'));
    await nextUtterance(tester);
    expect(tts.utterances.last, (text: 'Как дела?', lang: 'ru'));
    expect(translationLit(tester, 'translation-0-1'), isTrue);
    await nextUtterance(tester);
    await nextUtterance(tester);
    expect(tts.utterances.map((u) => u.text).toList(), [
      'Hello there.',
      'Привет.',
      'How are you?',
      'Как дела?',
      'Goodbye now.',
      'До свидания.',
    ]);
    expect(synthEngine.calls, isEmpty,
        reason: 'one run, one kind of voice: Russian needs the phone’s');
  });

  testWidgets('Both on the downloaded voice: each sentence, then its '
      'translation, each tagged with its own language', (tester) async {
    await addTranslation('es', const ['Hola.', '¿Cómo estás?', 'Adiós.']);
    await onPage();
    await pumpReader(tester, withSynthEngine: true);
    await readAloud(tester);

    expect(synthEngine.calls.map((c) => (c.text, c.lang)).toList().take(3), [
      ('Hello there.', 'en'),
      ('Hola.', 'es'),
      ('How are you?', 'en'),
    ]);
    expect(tts.utterances, isEmpty);

    synthEngine.complete(0);
    await tester.pump();
    queue.emitIndex(0);
    await tester.pump();
    synthEngine.complete(1);
    await tester.pump();
    queue.emitIndex(1);
    await tester.pump();
    expect(translationLit(tester, 'translation-0-0'), isTrue);
  });

  testWidgets('voice per language is remembered', (tester) async {
    await pumpReader(tester);
    await openVoices(tester);
    expect(find.byKey(const Key('read-aloud-voices-sheet')), findsOneWidget);
    expect(find.text('Russian'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    await tester.tap(find.byKey(Key('voice-ru-${ruVoiceB.name}')));
    await tester.pumpAndSettle();

    final prefs = await db.profilesDao.readerPrefs(profileId);
    expect(prefs.voices, {'ru': 'system:${ruVoiceB.name}'});

    // A fresh open of the reader reads Russian with the voice picked,
    // English with its own default.
    await tester.pumpWidget(const SizedBox());
    await pumpReader(tester);
    await readAloud(tester);
    await nextUtterance(tester);
    expect(tts.utterances, [
      (text: 'Hello there.', lang: 'en'),
      (text: 'Привет.', lang: 'ru'),
    ]);
    expect(tts.spokenVoices, [null, ruVoiceB]);
  });

  group('no voice for the language shows a plain message, not silence', () {
    testWidgets('Translation only, no Russian voice on the phone',
        (tester) async {
      tts.installed = [enVoice];
      await db.spineDao.setTranslationOnly(workId, true);
      await pumpReader(tester);
      await readAloud(tester);

      expect(find.textContaining('No Russian voice'), findsOneWidget);
      expect(find.textContaining('Text-to-speech'), findsOneWidget);
      expect(tts.utterances, isEmpty,
          reason: 'never Russian read by an English voice');
      expect(find.text('Read aloud'), findsOneWidget,
          reason: 'the bar is not left on Stop in silence');
    });

    testWidgets('Both: nothing starts, not even the English', (tester) async {
      tts.installed = [enVoice];
      await pumpReader(tester);
      await readAloud(tester);
      expect(find.textContaining('No Russian voice'), findsOneWidget);
      expect(tts.utterances, isEmpty);
      // ...and says how to hear the English alone.
      expect(find.textContaining('turn off “Read the Russian aloud too”'),
          findsOneWidget);
    });

    testWidgets('a phone whose only Russian voice needs the internet says '
        'so, not that it has none', (tester) async {
      tts.installed = [enVoice, ruNetwork];
      // Offline: Android turns the language down at the sentence.
      tts.refusedLangs = {'ru'};
      await db.spineDao.setTranslationOnly(workId, true);
      await pumpReader(tester);
      await readAloud(tester);
      await tester.pump();
      expect(find.textContaining('needs the internet'), findsOneWidget);
      expect(find.textContaining('No Russian voice'), findsNothing);
      expect(find.text('Read aloud'), findsOneWidget);
    });

    testWidgets('a phone that can\'t list its voices refuses at the '
        'sentence, and read aloud stops with the same message',
        (tester) async {
      tts.installed = null;
      tts.refusedLangs = {'ru'};
      await pumpReader(tester);
      await readAloud(tester);
      expect(tts.utterances, [(text: 'Hello there.', lang: 'en')]);
      await nextUtterance(tester);
      expect(find.textContaining('No Russian voice'), findsOneWidget);
      expect(find.text('Read aloud'), findsOneWidget);
      await nextUtterance(tester);
      expect(tts.utterances, hasLength(1));
    });

    testWidgets('the voices sheet says so too', (tester) async {
      tts.installed = [enVoice];
      await pumpReader(tester);
      await openVoices(tester);
      expect(find.byKey(const Key('voice-ru-none')), findsOneWidget);
      expect(find.textContaining('No Russian voice'), findsOneWidget);
    });
  });

  group('a voice that fails mid-run ends it with a plain message', () {
    testWidgets('a network voice: it needs the internet', (tester) async {
      tts.installed = [enVoice, ruNetwork];
      tts.failingLangs = {'ru'};
      await db.spineDao.setTranslationOnly(workId, true);
      await pumpReader(tester);
      await readAloud(tester);
      await tester.pump();
      expect(find.text('This voice needs the internet.'), findsOneWidget);
      expect(find.text('Read aloud'), findsOneWidget,
          reason: 'never left on Stop in silence');
    });

    testWidgets('a voice on the phone: it couldn’t play', (tester) async {
      tts.installed = [enVoice, ruVoiceA];
      tts.failingLangs = {'ru'};
      await db.spineDao.setTranslationOnly(workId, true);
      await pumpReader(tester);
      await readAloud(tester);
      await tester.pump();
      expect(find.text('Read aloud stopped: the voice couldn’t play.'),
          findsOneWidget);
      expect(find.text('Read aloud'), findsOneWidget);
    });
  });

  testWidgets('a translation being made is in the run\'s plan: Both never '
      'reads it with another language\'s voice when it arrives',
      (tester) async {
    final other = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'article',
        title: 'Other',
        persistence: 'work',
        firstSeenEpochDay: 100,
        lang: 'en');
    await db.spineDao.insertSegments(other, const [
      (idx: 0, kind: 'prose', text: 'Hello there. How are you?'),
    ]);
    // A browser's setLanguage says yes to anything: only the plan guards.
    tts.installed = [enVoice];
    final gate = _Gate();
    final fake = FakeTranslation(installed: {'opus-mt-en-es'});
    final service = TranslationService(
        registry: fakeTranslationRegistry,
        tier: DeviceTier.t2,
        store: fake.store,
        openSpec: (_) async => gate);
    await pumpReader(tester, translation: service, id: other);
    await tester.tap(find.byKey(const Key('reader-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('translate-action')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('translate-target-es')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('translation-progress')), findsOneWidget);

    await readAloud(tester);
    expect(find.textContaining('No Spanish voice'), findsOneWidget);
    expect(tts.utterances, isEmpty);
    gate.next('Hola.');
    await tester.pump();
    await tester.pump();
    gate.next('¿Cómo estás?');
    await tester.pumpAndSettle();
  });

  group('a new language started while another is stored', () {
    const esVoice = SystemVoice(name: 'es-es-x-eea-local', locale: 'es-ES');
    late _Gate gate;

    /// With Russian stored and showing, starts a translation into Spanish
    /// and holds it before its first sentence comes back.
    Future<void> startSpanish(WidgetTester tester) async {
      tts.installed = [enVoice, ruVoiceA, esVoice];
      gate = _Gate();
      final fake = FakeTranslation(installed: {'opus-mt-en-es'});
      final service = TranslationService(
          registry: fakeTranslationRegistry,
          tier: DeviceTier.t2,
          store: fake.store,
          openSpec: (_) async => gate);
      await onPage();
      await pumpReader(tester, translation: service);
      expect(find.textContaining(RegExp('[\u0400-\u04FF]')), findsWidgets);
      await tester.tap(find.byKey(const Key('reader-overflow')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('translate-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('translate-target-es')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('translation-progress')), findsOneWidget);
    }

    /// Leaves the reader, then lets the held run end.
    Future<void> release(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      for (final body in ['Hola.', '¿Cómo estás?', 'Adiós.']) {
        if (gate.pending == 0) break;
        gate.next(body);
        await tester.pump();
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    bool russian(String text) => RegExp('[\u0400-\u04FF]').hasMatch(text);

    testWidgets('Both: no Russian shows, and none is read as Spanish',
        (tester) async {
      await startSpanish(tester);
      expect(find.textContaining(RegExp('[\u0400-\u04FF]')), findsNothing);

      await readAloud(tester);
      for (var i = 0; i < 5; i++) {
        await nextUtterance(tester);
      }
      expect(tts.utterances, isNotEmpty);
      expect([for (final u in tts.utterances) if (russian(u.text)) u], isEmpty);
      await release(tester);
    });

    testWidgets('Translation only: the page shows no Russian while the '
        'Spanish is made', (tester) async {
      await db.spineDao.setTranslationOnly(workId, true);
      await startSpanish(tester);
      expect(find.textContaining(RegExp('[\u0400-\u04FF]')), findsNothing);
      expect(find.text('there.'), findsOneWidget, reason: 'the original shows');
      await release(tester);
    });
  });

  testWidgets('the phone\'s voices are listed once per visit', (tester) async {
    await db.spineDao.setTranslationOnly(workId, true);
    await pumpReader(tester);
    await readAloud(tester);
    await readAloud(tester); // Stop
    await readAloud(tester);
    expect(tts.utterances, hasLength(2));
    expect(tts.voicesCalls, 1);
  });

  testWidgets('an empty voice list (a browser still loading its voices) is '
      'asked again on the next run, not kept', (tester) async {
    tts.installed = [];
    await db.spineDao.setTranslationOnly(workId, true);
    await pumpReader(tester);
    await readAloud(tester);
    expect(tts.utterances, isEmpty);
    tts.installed = [enVoice, ruVoiceA];
    await readAloud(tester);
    expect(tts.utterances, [(text: 'Привет.', lang: 'ru')]);
    expect(tts.voicesCalls, 2);
  });

  testWidgets('Translation only picked during a Listen visit is remembered',
      (tester) async {
    await pumpReader(tester, speakTranslation: true);
    expect(await db.spineDao.translationOnly(workId), isFalse);
    await tester.tap(find.byKey(const Key('reader-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('translation-view-only')));
    await tester.pumpAndSettle();
    expect(await db.spineDao.translationOnly(workId), isTrue);
  });

  testWidgets('the voices sheet says when “Use the system voice” is on',
      (tester) async {
    await db.profilesDao.setPreferSystemVoice(profileId, true);
    await pumpReader(tester, withSynthEngine: true);
    await openVoices(tester);
    expect(find.textContaining('“Use the system voice” is on'),
        findsOneWidget);
    expect(find.byKey(const Key('voice-en-neural')), findsNothing);
  });

  test('voices are listed in a steady order, by place name: on the phone '
      'before needing the internet, then by name', () {
    final options = readAloudVoiceOptions('ru', neuralLangs: const {},
        installed: const [
          ruNetwork,
          SystemVoice(name: 'ru-ua-x-a-local', locale: 'ru-UA'),
          ruVoiceB,
          ruVoiceA,
        ]);
    expect([for (final o in options) (o.id, o.label, o.detail)], [
      (readAloudDefaultVoice, 'Default voice', null),
      ('system:${ruVoiceA.name}', 'Voice 1', 'Russian (Russia)'),
      ('system:${ruVoiceB.name}', 'Voice 2', 'Russian (Russia)'),
      ('system:${ruNetwork.name}', 'Voice 3',
          'Russian (Russia) · needs internet'),
      ('system:ru-ua-x-a-local', 'Voice 4', 'Russian (Ukraine)'),
    ]);
  });
}

/// A model whose every sentence waits for [next].
class _Gate implements SentenceTranslator {
  final _pending = <Completer<String>>[];

  void next(String body) => _pending.removeAt(0).complete(body);
  int get pending => _pending.length;

  @override
  Future<String> translate(String sentence) {
    final c = Completer<String>();
    _pending.add(c);
    return c.future;
  }

  @override
  Future<void> dispose() async {}
}
