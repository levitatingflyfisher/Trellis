import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_screen.dart';
import 'package:trellis/features/reader/translation/translation_service.dart';
import 'package:trellis/features/reader/translation/translator.dart';

import '../support/fake_translation_service.dart';

/// Translate, wired into the reader (ADR-0008 "Babel"; Campaign 8 "Babel
/// widens"; 1.5.5): the sheet lists every language the work can go into
/// with what each would download, one confirmation fetches the missing
/// legs, and the run translates directly or via English. Speak-in-
/// ⟨language⟩ and the dual display have their own test files.
void main() {
  late AppDatabase db;
  late int profileId;
  late int workId;

  setUp(() async {
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
  tearDown(() => db.close());

  Future<int> otherWork(String? lang, List<String> paragraphs) async {
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'article',
        title: 'Other',
        persistence: 'work',
        firstSeenEpochDay: 100,
        lang: lang);
    await db.spineDao.insertSegments(id, [
      for (final (i, p) in paragraphs.indexed)
        (idx: i, kind: 'prose', text: p),
    ]);
    return id;
  }

  Future<void> pumpReader(WidgetTester tester,
      {TranslationService? translation, int? id}) async {
    final work = (await db.spineDao.workById(id ?? workId))!;
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(
            db: db,
            profileId: profileId,
            work: work,
            translation: translation)));
    await tester.pumpAndSettle();
  }

  Future<void> openOverflow(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('reader-overflow')));
    await tester.pumpAndSettle();
  }

  Future<void> openSheet(WidgetTester tester) async {
    await openOverflow(tester);
    await tester.tap(find.byKey(const Key('translate-action')));
    await tester.pumpAndSettle();
  }

  Future<void> pick(WidgetTester tester, String lang) async {
    await openSheet(tester);
    await tester.tap(find.byKey(Key('translate-target-$lang')));
    await tester.pumpAndSettle();
  }

  /// The fake store's downloads beat on 100ms timers, which
  /// pumpAndSettle doesn't wait for once the bar stops animating.
  Future<void> settleDownloads(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
  }

  Future<void> scrollMode(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('mode-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mode-item-page')));
    await tester.pumpAndSettle();
  }

  String tileLine(WidgetTester tester, String lang) {
    final tile = tester.widget<ListTile>(find.byKey(Key('translate-target-$lang')));
    return (tile.subtitle! as Text).data!;
  }

  group('the sheet', () {
    testWidgets('no translation service (the web tier): no Translate action',
        (tester) async {
      await pumpReader(tester);
      await openOverflow(tester);
      expect(find.byKey(const Key('translate-action')), findsNothing);
    });

    testWidgets('offered with nothing downloaded: every reachable language, '
        'each with its download size, and never the work\'s own language',
        (tester) async {
      await pumpReader(tester, translation: FakeTranslation().service);
      await openSheet(tester);

      expect(find.text('Translate from English to…'), findsOneWidget);
      expect(tileLine(tester, 'de'), 'Download 200.0 MB');
      expect(tileLine(tester, 'es'), 'Download 100.0 MB');
      expect(tileLine(tester, 'ar'), 'Download 120.0 MB');
      expect(find.byKey(const Key('translate-target-en')), findsNothing,
          reason: 'never English to English');
      expect(find.byKey(const Key('translate-target-ja')), findsNothing,
          reason: 'no en->ja model exists');
    });

    testWidgets('an installed pair reads Ready', (tester) async {
      await pumpReader(tester,
          translation: FakeTranslation(installed: {'opus-mt-en-de'}).service);
      await openSheet(tester);
      expect(tileLine(tester, 'de'), 'Ready');
    });

    testWidgets('a work in no known language asks first, then lists from '
        'the answer', (tester) async {
      final id = await otherWork(null, ['Guten Tag.']);
      await pumpReader(tester, translation: FakeTranslation().service, id: id);
      await openOverflow(tester);
      expect(find.text('Language: not set'), findsOneWidget,
          reason: 'never assumed to be English');
      await tester.tap(find.byKey(const Key('translate-action')));
      await tester.pumpAndSettle();

      expect(find.text('What language is this in?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('work-language-de')));
      await tester.pumpAndSettle();

      expect(find.text('Translate from German to…'), findsOneWidget);
      expect(find.byKey(const Key('translate-target-en')), findsOneWidget);
      expect((await db.spineDao.workById(id))!.lang, 'de');
    });

    testWidgets('a feed\'s declared language stands in for a work with '
        'none', (tester) async {
      final id = await otherWork(null, ['Guten Tag.']);
      final feed = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://f', title: 'Show');
      await (db.update(db.feeds)..where((f) => f.id.equals(feed)))
          .write(const FeedsCompanion(language: Value('de-DE')));
      await db.feedsDao.insertEpisode(
          workId: id, feedId: feed, guid: 'g', publishedAtMs: 1);
      await pumpReader(tester, translation: FakeTranslation().service, id: id);
      await openSheet(tester);
      expect(find.text('Translate from German to…'), findsOneWidget);
    });
  });

  group('download, then translate', () {
    testWidgets('the sheet offers the download with its size; one '
        'confirmation downloads it with progress, then it translates',
        (tester) async {
      final fake = FakeTranslation(beats: 3);
      await pumpReader(tester, translation: fake.service);
      await pick(tester, 'de');

      expect(find.byKey(const Key('consent-dialog')), findsOneWidget);
      expect(find.text('• English to German translator, 200.0 MB'),
          findsOneWidget);
      await tester.tap(find.byKey(const Key('consent-accept')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final card = find.byKey(const Key('translation-download'));
      expect(card, findsOneWidget);
      expect(
          find.descendant(
              of: card,
              matching: find.textContaining('English to German translator')),
          findsOneWidget);
      await settleDownloads(tester);

      expect(fake.store.downloadsStarted, ['opus-mt-en-de']);
      expect(find.byKey(const Key('translation-download')), findsNothing);
      final stored = await db.spineDao.translationSentencesOf(workId, lang: 'de');
      expect(stored[(0, 0)]!.body, 'de:Hello there.');
      expect(stored[(1, 0)]!.body, 'de:Goodbye now.');
      expect(await db.spineDao.activeTranslationLang(workId), 'de');
      expect(fake.opened.single.disposed, isTrue,
          reason: 'the model is freed when the run ends');
      await scrollMode(tester);
      expect(find.byKey(const Key('translation-0-0')), findsOneWidget,
          reason: 'the translation shows under its sentence');
    });

    testWidgets('declining the download starts nothing', (tester) async {
      final fake = FakeTranslation();
      await pumpReader(tester, translation: fake.service);
      await pick(tester, 'de');
      await tester.tap(find.byKey(const Key('consent-cancel')));
      await tester.pumpAndSettle();

      expect(fake.store.downloadsStarted, isEmpty);
      expect(await db.spineDao.activeTranslationLang(workId), isNull);
    });

    testWidgets('cancelling the download keeps what arrived and translates '
        'nothing', (tester) async {
      final fake = FakeTranslation(beats: 5);
      await pumpReader(tester, translation: fake.service);
      await pick(tester, 'de');
      await tester.tap(find.byKey(const Key('consent-accept')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      await tester.tap(find.byKey(const Key('translation-download-cancel')));
      await settleDownloads(tester);

      expect(find.byKey(const Key('translation-download')), findsNothing);
      expect(fake.store.partial['opus-mt-en-de'], greaterThan(0));
      expect(await db.spineDao.hasTranslationSentences(workId, lang: 'de'),
          isFalse);
    });

    testWidgets('via English: the sheet says so, one confirmation names '
        'both legs and the total, and the run goes through English',
        (tester) async {
      final id = await otherWork('de', ['Guten Tag.']);
      final fake = FakeTranslation(installed: {'opus-mt-de-en'});
      await pumpReader(tester, translation: fake.service, id: id);
      await openSheet(tester);
      expect(tileLine(tester, 'es'), 'Via English · Download 100.0 MB',
          reason: 'only the missing leg counts');
      expect(tileLine(tester, 'en'), 'Ready');
      await tester.tap(find.byKey(const Key('translate-target-es')));
      await tester.pumpAndSettle();
      expect(find.text('• English to Spanish translator, 100.0 MB'),
          findsOneWidget);
      await tester.tap(find.byKey(const Key('consent-accept')));
      await settleDownloads(tester);

      final es = await db.spineDao.translationSentencesOf(id, lang: 'es');
      expect(es[(0, 0)]!.body, 'es:en:Guten Tag.');
      expect(es[(0, 0)]!.sourceText, 'Guten Tag.');
      expect(await db.spineDao.activeTranslationLang(id), 'es');
    });

    testWidgets('both legs missing: both listed, with the total',
        (tester) async {
      final id = await otherWork('ja', ['こんにちは。']);
      await pumpReader(tester, translation: FakeTranslation().service, id: id);
      await pick(tester, 'de');
      expect(find.text('• Japanese to English translator, 300.0 MB'),
          findsOneWidget);
      expect(find.text('• English to German translator, 200.0 MB'),
          findsOneWidget);
      expect(find.text('• 500.0 MB in all, to translate via English'),
          findsOneWidget);
    });
  });

  group('running', () {
    testWidgets('a calm progress card while it runs; Cancel keeps what is '
        'done', (tester) async {
      final gate = _Gate();
      final fake = FakeTranslation(installed: {'opus-mt-en-es'});
      final service = TranslationService(
          registry: fakeTranslationRegistry,
          tier: DeviceTier.t2,
          store: fake.store,
          openSpec: (_) async => gate);
      await pumpReader(tester, translation: service);
      await pick(tester, 'es');
      await tester.pump();

      expect(find.byKey(const Key('translation-progress')), findsOneWidget);
      gate.next('ES: Hello there.');
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const Key('translation-cancel')));
      await tester.pump();
      gate.next('ES: How are you?');
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('translation-progress')), findsNothing);
      final stored = await db.spineDao.translationSentencesOf(workId, lang: 'es');
      expect(stored.keys.toSet(), {(0, 0), (0, 1)});
      expect(gate.calls, 2, reason: 'the third sentence never started');
      expect(gate.disposed, isTrue);
      expect(await db.spineDao.translationRunLang(workId), isNull,
          reason: 'a cancelled run is not resumed');
    });

    testWidgets('a run the system killed resumes on the next open, '
        'translating only what is missing', (tester) async {
      await db.spineDao.setActiveTranslationLang(workId, 'es');
      await db.spineDao.setTranslationRunLang(workId, 'es');
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: 'es',
          sourceText: 'Hello there.',
          body: 'es:Hello there.');
      final fake = FakeTranslation(installed: {'opus-mt-en-es'});
      await pumpReader(tester, translation: fake.service);
      await tester.pumpAndSettle();

      expect(fake.opened.single.calls, ['How are you?', 'Goodbye now.']);
      expect(
          (await db.spineDao.translationSentencesOf(workId, lang: 'es')).length,
          3);
      expect(await db.spineDao.translationRunLang(workId), isNull);
    });

    testWidgets('leaving the reader mid-run keeps the run for next time',
        (tester) async {
      final gate = _Gate();
      final fake = FakeTranslation(installed: {'opus-mt-en-es'});
      final service = TranslationService(
          registry: fakeTranslationRegistry,
          tier: DeviceTier.t2,
          store: fake.store,
          openSpec: (_) async => gate);
      await pumpReader(tester, translation: service);
      await pick(tester, 'es');
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      gate.next('ES: Hello there.');
      await tester.pumpAndSettle();

      expect(await db.spineDao.translationRunLang(workId), 'es');
      expect(gate.calls, 1);
      expect(gate.disposed, isTrue, reason: 'the model is freed on leaving');
    });

    testWidgets('picking a second language replaces the active one; the '
        'first one\'s rows stay', (tester) async {
      final fake =
          FakeTranslation(installed: {'opus-mt-en-es', 'opus-mt-en-de'});
      await pumpReader(tester, translation: fake.service);
      await pick(tester, 'es');
      await tester.pumpAndSettle();
      await pick(tester, 'de');
      await tester.pumpAndSettle();

      expect(await db.spineDao.activeTranslationLang(workId), 'de');
      expect(await db.spineDao.hasTranslationSentences(workId, lang: 'es'),
          isTrue);
    });

    testWidgets('an Arabic translation reads right to left', (tester) async {
      final fake = FakeTranslation(installed: {'opus-mt-en-ar'});
      await pumpReader(tester, translation: fake.service);
      await pick(tester, 'ar');
      await tester.pumpAndSettle();
      await scrollMode(tester);

      final line =
          tester.widget<Text>(find.byKey(const Key('translation-0-0')));
      expect(line.textDirection, TextDirection.rtl);
    });
  });

  group('the per-work language selector', () {
    testWidgets('picking a language persists it and re-labels the item',
        (tester) async {
      await pumpReader(tester);
      await openOverflow(tester);
      expect(find.text('Language: English'), findsOneWidget);
      await tester.tap(find.byKey(const Key('work-language-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('work-language-de')));
      await tester.pumpAndSettle();

      expect((await db.spineDao.workById(workId))!.lang, 'de');
      await openOverflow(tester);
      expect(find.text('Language: German'), findsOneWidget);
    });

    testWidgets('the sheet follows a changed language', (tester) async {
      await pumpReader(tester, translation: FakeTranslation().service);
      await openOverflow(tester);
      await tester.tap(find.byKey(const Key('work-language-action')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('work-language-de')));
      await tester.pumpAndSettle();
      await openSheet(tester);

      expect(find.text('Translate from German to…'), findsOneWidget);
      expect(find.byKey(const Key('translate-target-de')), findsNothing);
    });
  });

  group('Show ⟨language⟩', () {
    testWidgets('absent until a translation is stored', (tester) async {
      await pumpReader(tester, translation: FakeTranslation().service);
      await openOverflow(tester);
      expect(find.byKey(const Key('show-translation-toggle')), findsNothing);
    });

    testWidgets('labeled with the active language, persisted through the DAO',
        (tester) async {
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
      expect(find.text('Show German'), findsOneWidget);
      expect(await db.spineDao.showTranslationLayer(workId), isTrue);

      await tester.tap(find.byKey(const Key('show-translation-toggle')));
      await tester.pumpAndSettle();
      expect(await db.spineDao.showTranslationLayer(workId), isFalse);
    });

    testWidgets('an active language with no stored rows offers no toggle — '
        'no dead settings', (tester) async {
      await db.spineDao.setActiveTranslationLang(workId, 'de');
      await pumpReader(tester);
      await openOverflow(tester);
      expect(find.byKey(const Key('show-translation-toggle')), findsNothing);
      expect(find.byKey(const Key('speak-translation-toggle')), findsNothing);
    });
  });

  testWidgets('X->en end to end: a German work translates into English and '
      'offers Show English', (tester) async {
    final id = await otherWork('de', ['Hallo dort. Wie geht es dir?']);
    final fake = FakeTranslation(installed: {'opus-mt-de-en'});
    await pumpReader(tester, translation: fake.service, id: id);
    await pick(tester, 'en');
    await tester.pumpAndSettle();

    final stored = await db.spineDao.translationSentencesOf(id, lang: 'en');
    expect(stored[(0, 1)]!.body, 'en:Wie geht es dir?');
    await openOverflow(tester);
    expect(find.text('Show English'), findsOneWidget);
  });

  testWidgets('a via-English run says so and counts each step\'s sentences, '
      'not a doubled total', (tester) async {
    final id = await otherWork('de', ['Eins. Zwei.']);
    final gate = _Gate();
    final fake = FakeTranslation(installed: {'opus-mt-de-en', 'opus-mt-en-es'});
    final service = TranslationService(
        registry: fakeTranslationRegistry,
        tier: DeviceTier.t2,
        store: fake.store,
        openSpec: (_) async => gate);
    await pumpReader(tester, translation: service, id: id);
    await pick(tester, 'es');
    await tester.pump();
    gate.next('One.');
    await tester.pump();
    await tester.pump();

    expect(find.text('Translating to Spanish via English, step 1 of 2: '
        '1 of 2 sentences'), findsOneWidget);
    gate.next('Two.');
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('step 2 of 2: 0 of 2 sentences'),
        findsOneWidget);
    gate.next('Uno.');
    await tester.pump();
    gate.next('Dos.');
    await tester.pumpAndSettle();
  });

}

/// A model whose every sentence waits for [next]: a test can watch a run
/// mid-sentence and decide how far it gets.
class _Gate implements SentenceTranslator {
  final _pending = <Completer<String>>[];
  int calls = 0;
  bool disposed = false;

  void next(String body) => _pending.removeAt(0).complete(body);

  @override
  Future<String> translate(String sentence) {
    calls++;
    final c = Completer<String>();
    _pending.add(c);
    return c.future;
  }

  @override
  Future<void> dispose() async => disposed = true;
}
