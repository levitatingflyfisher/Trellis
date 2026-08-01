import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_screen.dart';
import 'package:trellis/features/reader/translation/marian_engine.dart';

import '../support/fake_marian_translator.dart';

/// The "Translate…" batch action, wired into the reader (ADR-0008 "Babel"
/// Phase 3; generalized to any (source, target) pair by Campaign 8 "Babel
/// widens" Phase 1): the model gate, the target-language picker, the
/// cancellable/resumable run, and the "Show ⟨language⟩" toggle it unlocks.
/// Speak-in-⟨language⟩ and the scroll-mode dual display are covered in
/// their own test files.
void main() {
  late Directory dir;
  late AppDatabase db;
  late int profileId;
  late int workId;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('trellis-reader-translate');
    db = AppDatabase.forTesting(NativeDatabase.memory());
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
  });
  tearDown(() {
    db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> pumpReader(
    WidgetTester tester, {
    List<String> targets = const [],
    Future<MarianTranslator?> Function({
      required String sourceLang,
      required String targetLang,
    })? resolveTranslator,
  }) async {
    final work =
        (await db.spineDao.worksOf(profileId)).firstWhere((w) => w.id == workId);
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(
            db: db,
            profileId: profileId,
            work: work,
            availableTranslationTargets: ({required sourceLang}) async => targets,
            resolveTranslator: resolveTranslator)));
    await tester.pumpAndSettle();
  }

  Future<void> openOverflow(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('reader-overflow')));
    await tester.pumpAndSettle();
  }

  /// Opens the overflow menu, taps "Translate…", then taps the picker
  /// option for [lang] — the full path a real reader takes.
  Future<void> pickTranslateTarget(WidgetTester tester, String lang) async {
    await openOverflow(tester);
    await tester.tap(find.byKey(const Key('translate-action')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('translate-target-$lang')));
    await tester.pumpAndSettle();
  }

  group('the model gate', () {
    testWidgets('no availableTranslationTargets at all: no Translate '
        'action ever offered', (tester) async {
      await pumpReader(tester);
      await openOverflow(tester);
      expect(find.byKey(const Key('translate-action')), findsNothing);
    });

    testWidgets('availableTranslationTargets resolving to an empty list: '
        'no Translate action', (tester) async {
      await pumpReader(tester, targets: const []);
      await openOverflow(tester);
      expect(find.byKey(const Key('translate-action')), findsNothing);
    });

    testWidgets('a non-empty target list offers the action, and the '
        'picker lists each one', (tester) async {
      await pumpReader(tester, targets: const ['es', 'de']);
      await openOverflow(tester);
      expect(find.byKey(const Key('translate-action')), findsOneWidget);

      await tester.tap(find.byKey(const Key('translate-action')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('translate-target-es')), findsOneWidget);
      expect(find.byKey(const Key('translate-target-de')), findsOneWidget);
      expect(find.text('Spanish'), findsOneWidget);
      expect(find.text('German'), findsOneWidget);
    });

    testWidgets('Campaign 8 "Babel widens": the work\'s own declared '
        'source language is never offered as a target, even if somehow '
        'present in the list', (tester) async {
      // A misbehaving caller passing 'en' back for an 'en'-source work —
      // the picker itself is the reader's defense either way, but this
      // proves availableTranslationTargets is exactly what gates the
      // picker's OWN option list end to end.
      await pumpReader(tester, targets: const ['en', 'es']);
      await openOverflow(tester);
      await tester.tap(find.byKey(const Key('translate-action')));
      await tester.pumpAndSettle();
      // The picker renders exactly what it's given — the REAL guard
      // against en->en lives one layer down, in resolveTranslator's own
      // refusal (see the next test) and in DeviceServices
      // .availableTranslationTargets (device_services_translation_test
      // .dart), which never returns the source language in the first
      // place. This test documents that even if the list were somehow
      // wrong, starting a translate for the source language itself is
      // refused.
      expect(find.byKey(const Key('translate-target-en')), findsOneWidget);
      await tester.tap(find.byKey(const Key('translate-target-en')));
      await tester.pumpAndSettle();
      // Refused silently — no progress card, nothing stored.
      expect(find.byKey(const Key('translation-progress')), findsNothing);
      expect(
          await db.spineDao.hasTranslationSentences(workId, lang: 'en'),
          isFalse);
    });

    testWidgets('resolveTranslator resolving to null for the chosen '
        'target: no batch starts, no progress card', (tester) async {
      await pumpReader(tester,
          targets: const ['es'],
          resolveTranslator: ({required sourceLang, required targetLang}) async =>
              null);
      await pickTranslateTarget(tester, 'es');
      expect(find.byKey(const Key('translation-progress')), findsNothing);
    });
  });

  group('running the batch', () {
    testWidgets('picking a target runs to completion, persists every '
        'sentence, and shows a calm progress card meanwhile', (tester) async {
      final gate = <Completer<String>>[];
      final handle = _GatedHandle(gate);
      final gatedTranslator = MarianTranslator(
        files: fakeMarianTranslatorFiles(dir),
        openHandle: (_) async => handle,
      );

      await pumpReader(tester,
          targets: const ['es'],
          resolveTranslator: ({required sourceLang, required targetLang}) async {
            expect(sourceLang, 'en');
            expect(targetLang, 'es');
            return gatedTranslator;
          });
      await pickTranslateTarget(tester, 'es');
      await tester.pump();

      expect(find.byKey(const Key('translation-progress')), findsOneWidget);

      gate[0].complete('ES: Hello there.');
      await tester.pump();
      await tester.pump();
      gate[1].complete('ES: How are you?');
      await tester.pump();
      await tester.pump();
      gate[2].complete('ES: Goodbye now.');
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('translation-progress')), findsNothing,
          reason: 'the card clears once the run is done');

      final stored = await db.spineDao.translationSentencesOf(workId, lang: 'es');
      expect(stored.length, 3);
      expect(stored[(0, 0)]!.body, 'ES: Hello there.');
      expect(stored[(0, 1)]!.body, 'ES: How are you?');
      expect(stored[(1, 0)]!.body, 'ES: Goodbye now.');
      expect(await db.spineDao.activeTranslationLang(workId), 'es',
          reason: 'picking a target persists it as the one active layer');
    });

    testWidgets('cancel keeps what is done and clears the progress card',
        (tester) async {
      final gate = <Completer<String>>[];
      final handle = _GatedHandle(gate);
      final translator = MarianTranslator(
        files: fakeMarianTranslatorFiles(dir),
        openHandle: (_) async => handle,
      );

      await pumpReader(tester,
          targets: const ['es'],
          resolveTranslator: ({required sourceLang, required targetLang}) async =>
              translator);
      await pickTranslateTarget(tester, 'es');
      await tester.pump();

      // Cancel is checked at the top of each iteration — a sentence
      // already in flight still finishes; only the NEXT one never starts.
      gate[0].complete('ES: Hello there.');
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('translation-cancel')), findsOneWidget);
      await tester.tap(find.byKey(const Key('translation-cancel')));
      await tester.pump();
      gate[1].complete('ES: How are you?');
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('translation-progress')), findsNothing);
      final stored = await db.spineDao.translationSentencesOf(workId, lang: 'es');
      expect(stored.length, 2);
      expect(stored.containsKey((0, 0)), isTrue);
      expect(stored.containsKey((0, 1)), isTrue);
      expect(stored.containsKey((1, 0)), isFalse,
          reason: 'the third sentence never started');
      expect(gate.length, 2, reason: 'translate() was never called a third time');
    });

    testWidgets('picking a SECOND target replaces the active layer — one '
        'active translation layer per work at a time', (tester) async {
      await pumpReader(tester,
          targets: const ['es', 'de'],
          resolveTranslator: ({required sourceLang, required targetLang}) async =>
              fakeMarianTranslator(dir,
                  translateFn: (s) => '$targetLang: $s'));
      await pickTranslateTarget(tester, 'es');
      await tester.pumpAndSettle();
      expect(await db.spineDao.activeTranslationLang(workId), 'es');

      await pickTranslateTarget(tester, 'de');
      await tester.pumpAndSettle();
      expect(await db.spineDao.activeTranslationLang(workId), 'de',
          reason: 'the slot holds exactly one language, never both');
      // The 'es' rows are NOT deleted — just no longer active.
      expect(await db.spineDao.hasTranslationSentences(workId, lang: 'es'),
          isTrue);
    });
  });

  group('the calm per-work language selector (Campaign 8 "Babel '
      'widens" Phase 1)', () {
    testWidgets('always offered, labeled with the current language, '
        'defaulting to English for a work with none declared',
        (tester) async {
      final noLangWorkId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'article',
          title: 'B',
          persistence: 'work',
          firstSeenEpochDay: 100);
      await db.spineDao.insertSegments(noLangWorkId, const [
        (idx: 0, kind: 'prose', text: 'Hi.'),
      ]);
      final work = (await db.spineDao.worksOf(profileId))
          .firstWhere((w) => w.id == noLangWorkId);
      await tester.pumpWidget(MaterialApp(
          home: ReaderScreen(db: db, profileId: profileId, work: work)));
      await tester.pumpAndSettle();
      await openOverflow(tester);
      expect(find.text('Language: English'), findsOneWidget);
    });

    testWidgets('picking a language persists it through the DAO and '
        're-labels the menu item', (tester) async {
      await pumpReader(tester);
      await openOverflow(tester);
      await tester.tap(find.byKey(const Key('work-language-action')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('work-language-de')), findsOneWidget);
      await tester.tap(find.byKey(const Key('work-language-de')));
      await tester.pumpAndSettle();

      expect((await db.spineDao.workById(workId))!.lang, 'de');
      await openOverflow(tester);
      expect(find.text('Language: German'), findsOneWidget);
    });

    testWidgets('re-derives the "Translate…" picker\'s options for the '
        'NEW source language — a language change is not a stale cache',
        (tester) async {
      final sourceLangCalls = <String>[];
      final work =
          (await db.spineDao.worksOf(profileId)).firstWhere((w) => w.id == workId);
      await tester.pumpWidget(MaterialApp(
          home: ReaderScreen(
              db: db,
              profileId: profileId,
              work: work,
              availableTranslationTargets: ({required sourceLang}) async {
                sourceLangCalls.add(sourceLang);
                return const [];
              })));
      await tester.pumpAndSettle();
      expect(sourceLangCalls, ['en']);

      await openOverflow(tester);
      await tester.tap(find.byKey(const Key('work-language-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('work-language-de')));
      await tester.pumpAndSettle();

      expect(sourceLangCalls, ['en', 'de'],
          reason: 'picking a new language triggers a fresh _load(), which '
              'asks availableTranslationTargets again with the NEW '
              'sourceLang — the options are re-derived, not cached from '
              'the first load');
    });
  });

  group('Show ⟨language⟩', () {
    testWidgets('the toggle is absent until a translation layer is '
        'active', (tester) async {
      await pumpReader(tester,
          targets: const ['es'],
          resolveTranslator: ({required sourceLang, required targetLang}) async =>
              fakeMarianTranslator(dir));
      await openOverflow(tester);
      expect(find.byKey(const Key('show-translation-toggle')), findsNothing);
    });

    testWidgets('once a target is active, the toggle appears labeled with '
        'that language and persists through the DAO', (tester) async {
      await db.spineDao.setActiveTranslationLang(workId, 'de');
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: 'de',
          sourceText: 'Hello there.',
          body: 'Hallo.');
      await pumpReader(tester);
      await openOverflow(tester);
      expect(find.byKey(const Key('show-translation-toggle')), findsOneWidget);
      expect(find.text('Show German'), findsOneWidget);
      // setActiveTranslationLang already turns the legacy show-toggle on
      // (see SpineDao's own sync law) — starts checked.
      expect(await db.spineDao.showTranslationLayer(workId), isTrue);

      await tester.tap(find.byKey(const Key('show-translation-toggle')));
      await tester.pumpAndSettle();

      expect(await db.spineDao.showTranslationLayer(workId), isFalse);
    });

    testWidgets('an active language with ZERO stored rows offers no '
        'toggle — no dead settings. setActiveTranslationLang runs before '
        'a batch produces its first sentence (so the progress card can '
        'show right away); a batch cancelled at zero rows, or a work '
        'reopened mid-run, must not leave a control with nothing behind '
        'it', (tester) async {
      await db.spineDao.setActiveTranslationLang(workId, 'de');
      // No upsertTranslationSentence call — the slot is claimed, nothing
      // is stored yet.
      await pumpReader(tester);
      await openOverflow(tester);
      expect(find.byKey(const Key('show-translation-toggle')), findsNothing);
      expect(find.byKey(const Key('speak-translation-toggle')), findsNothing);
    });

    testWidgets('a pre-campaign work with stored Spanish but the display '
        'toggled OFF still offers the toggle on reopen — turning display '
        'off must never look like "no translation exists"', (tester) async {
      // Simulates 1.3.0 data: rows exist under 'es', activeTranslationLang
      // was never written (the column postdates this data), and the user
      // had switched the legacy show-toggle off before this campaign
      // shipped.
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: 'es',
          sourceText: 'Hello there.',
          body: 'Hola.');
      await db.spineDao.setShowTranslationLayer(workId, false);
      expect(await db.spineDao.activeTranslationLang(workId), isNull,
          reason: 'this column never got written by the pre-campaign flow');

      await pumpReader(tester);
      await openOverflow(tester);
      expect(find.byKey(const Key('show-translation-toggle')), findsOneWidget,
          reason: 'the stored Spanish is still there — only its display '
              'was off, which is not the same as not existing');
      expect(find.text('Show Spanish'), findsOneWidget);
    });
  });

  group('Campaign 8 "Babel widens" Phase 4: the X->en secondary '
      'direction, end to end (Phase 1 generalized the picker by '
      'sourceLang; device_services_translation_test.dart already proves '
      'the registry resolves de-en/ru-en/zh-en correctly — this closes '
      'the claim by proving the FULL reader flow, not just the lookup)',
      () {
    testWidgets('a German-sourced work offers English as a translate '
        'target, and the picker -> batch -> display -> active-lang flow '
        'works the SAME way the forward direction does', (tester) async {
      final deWorkId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'article',
          title: 'Eine Geschichte',
          persistence: 'work',
          firstSeenEpochDay: 100,
          lang: 'de');
      await db.spineDao.insertSegments(deWorkId, const [
        (idx: 0, kind: 'prose', text: 'Hallo dort. Wie geht es dir?'),
      ]);
      final work =
          (await db.spineDao.worksOf(profileId)).firstWhere((w) => w.id == deWorkId);

      final sourceLangCalls = <String>[];
      await tester.pumpWidget(MaterialApp(
          home: ReaderScreen(
              db: db,
              profileId: profileId,
              work: work,
              availableTranslationTargets: ({required sourceLang}) async {
                sourceLangCalls.add(sourceLang);
                return sourceLang == 'de' ? const ['en'] : const [];
              },
              resolveTranslator: ({required sourceLang, required targetLang}) async {
                expect(sourceLang, 'de');
                expect(targetLang, 'en');
                return fakeMarianTranslator(dir,
                    translateFn: (s) => 'EN: $s');
              })));
      await tester.pumpAndSettle();
      expect(sourceLangCalls, ['de'],
          reason: 'the picker\'s options are derived from the WORK\'S OWN '
              'declared source language, de here — never hardcoded en');

      await openOverflow(tester);
      await tester.tap(find.byKey(const Key('translate-action')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('translate-target-en')), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      await tester.tap(find.byKey(const Key('translate-target-en')));
      await tester.pumpAndSettle();

      final stored =
          await db.spineDao.translationSentencesOf(deWorkId, lang: 'en');
      expect(stored.length, 2);
      expect(stored[(0, 0)]!.body, 'EN: Hallo dort.');
      expect(stored[(0, 1)]!.body, 'EN: Wie geht es dir?');
      expect(await db.spineDao.activeTranslationLang(deWorkId), 'en');

      await openOverflow(tester);
      expect(find.text('Show English'), findsOneWidget);
    });
  });
}

/// A translator whose translate() suspends on a per-call Completer, so a
/// test can watch the batch mid-run and control exactly how many
/// sentences complete before cancelling.
class _GatedHandle implements MarianModelHandle {
  final List<Completer<String>> gate;
  _GatedHandle(this.gate);

  @override
  Future<String> translate(String sentence) {
    final c = Completer<String>();
    gate.add(c);
    return c.future;
  }

  @override
  Future<void> dispose() async {}
}
