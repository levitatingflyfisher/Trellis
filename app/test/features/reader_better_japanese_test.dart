import 'package:brain_wiring/brain_wiring.dart' show AskException;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ml_runtime/ml_runtime.dart' show DeviceTier;
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_screen.dart';
import 'package:trellis/features/reader/translation/translation_service.dart';

import '../support/fake_translation_service.dart';
import 'brain_test_support.dart';

/// "Better Japanese" (board-0126 point 2): the bring-your-own-key brain
/// translator, offered in the Translate sheet beside the offline
/// translators for an English work, labelled plainly as online, sent to
/// Anthropic with the listener's key, and what it costs. Nothing leaves
/// the device before a real yes.
void main() {
  late AppDatabase db;
  late InMemorySecretStore secrets;
  late int profileId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    secrets = InMemorySecretStore();
    profileId = await db.profilesDao.create('Ada');
  });
  tearDown(() => db.close());

  Future<Work> work(String? lang) async {
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'article',
        title: 'A Story',
        persistence: 'work',
        firstSeenEpochDay: 100,
        lang: lang);
    await db.spineDao.insertSegments(id, const [
      (idx: 0, kind: 'prose', text: 'Hello there. How are you?'),
      (idx: 1, kind: 'prose', text: 'Goodbye now.'),
    ]);
    return (await db.spineDao.workById(id))!;
  }

  void configureAnthropic() {
    secrets.values['brain.tier'] = 'byokAnthropic';
    secrets.values['brain.anthropic_api_key'] = 'sk-ant-k';
  }

  Future<void> openSheet(WidgetTester tester, Work w,
      {FakeBrain? brain, TranslationService? translation}) async {
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(
            db: db,
            profileId: profileId,
            work: w,
            translation: translation ?? FakeTranslation().service,
            brain: fakeBrainStore(secrets: secrets, brain: brain))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reader-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('translate-action')));
    await tester.pumpAndSettle();
  }

  const better = Key('translate-better-ja');

  testWidgets('with an Anthropic key, an English work is offered better '
      'Japanese, labelled as online, sent with the key, and its cost',
      (tester) async {
    configureAnthropic();
    await openSheet(tester, await work('en'), brain: FakeBrain(const []));

    expect(find.byKey(better), findsOneWidget);
    final tile = tester.widget<ListTile>(find.byKey(better));
    expect((tile.title! as Text).data, 'Japanese, better');
    final line = (tile.subtitle! as Text).data!;
    expect(line, contains('Online'));
    expect(line, contains('Anthropic’s Claude'));
    expect(line, contains('your key'));
    expect(line, contains('cent'));
  });

  testWidgets('without a key there is no such choice', (tester) async {
    await openSheet(tester, await work('en'));
    expect(find.byKey(better), findsNothing);
  });

  testWidgets('a key kept while another brain is chosen is not used',
      (tester) async {
    configureAnthropic();
    secrets.values['brain.tier'] = 'none';
    await openSheet(tester, await work('en'), brain: FakeBrain(const []));
    expect(find.byKey(better), findsNothing);
  });

  testWidgets('a work not in English is not offered it', (tester) async {
    configureAnthropic();
    await openSheet(tester, await work('de'), brain: FakeBrain(const []));
    expect(find.byKey(better), findsNothing);
  });

  testWidgets('choosing it asks first, naming where the text goes; no '
      'sends nothing and stores nothing', (tester) async {
    configureAnthropic();
    final brain = FakeBrain(const []);
    final w = await work('en');
    await openSheet(tester, w, brain: brain);
    await tester.tap(find.byKey(better));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('consent-dialog')), findsOneWidget);
    expect(find.text('Send to Anthropic?'), findsOneWidget);
    expect(find.textContaining('api.anthropic.com'), findsOneWidget);
    expect(find.textContaining('“A Story”'), findsOneWidget);
    expect(find.textContaining('About 1 cent'), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
    await tester.tap(find.byKey(const Key('consent-cancel')));
    await tester.pumpAndSettle();

    expect(brain.callCount, 0);
    expect(await db.spineDao.translationSentencesOf(w.id, lang: 'ja'),
        isEmpty);
  });

  testWidgets('yes translates in one request per chunk and stores the '
      'Japanese, marked as made by the Anthropic brain', (tester) async {
    configureAnthropic();
    final brain = FakeBrain(const [
      '{"translations": ["こんにちは。", "お元気ですか？", "さようなら。"]}',
    ]);
    final w = await work('en');
    await openSheet(tester, w, brain: brain);
    await tester.tap(find.byKey(better));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('consent-accept')));
    await tester.pumpAndSettle();

    expect(brain.callCount, 1);
    final rows =
        await db.spineDao.translationSentencesOf(w.id, lang: 'ja');
    expect({for (final e in rows.entries) e.key: e.value.body}, {
      (0, 0): 'こんにちは。',
      (0, 1): 'お元気ですか？',
      (1, 0): 'さようなら。',
    });
    expect({for (final r in rows.values) r.engine}, {'domovoi:byokAnthropic'});
  });

  testWidgets('Japanese made offline before is replaced, not kept',
      (tester) async {
    configureAnthropic();
    final w = await work('en');
    for (final (seg, i, text) in [
      (0, 0, 'Hello there.'),
      (0, 1, 'How are you?'),
      (1, 0, 'Goodbye now.'),
    ]) {
      await db.spineDao.upsertTranslationSentence(
          workId: w.id,
          segmentIdx: seg,
          sentenceIdx: i,
          lang: 'ja',
          sourceText: text,
          body: '機械',
          engine: 'marian');
    }
    final brain = FakeBrain(const [
      '{"translations": ["こんにちは。", "お元気ですか？", "さようなら。"]}',
    ]);
    await openSheet(tester, w, brain: brain);
    await tester.tap(find.byKey(better));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('consent-accept')));
    await tester.pumpAndSettle();

    expect(brain.callCount, 1);
    final rows =
        await db.spineDao.translationSentencesOf(w.id, lang: 'ja');
    expect(rows[(1, 0)]!.body, 'さようなら。');
    expect({for (final r in rows.values) r.engine}, {'domovoi:byokAnthropic'});
  });

  testWidgets('when Anthropic sends nothing back, the reader says so',
      (tester) async {
    configureAnthropic();
    final w = await work('en');
    await openSheet(tester, w,
        brain: FakeBrain([AskException('Anthropic is busy right now.')]));
    await tester.tap(find.byKey(better));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('consent-accept')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Anthropic didn’t translate every sentence'),
        findsOneWidget);
    expect(await db.spineDao.translationSentencesOf(w.id, lang: 'ja'),
        isEmpty);
  });

  testWidgets('the app’s translation service carries the brain store, so '
      'every reader is offered it, not only one handed a store',
      (tester) async {
    configureAnthropic();
    final fake = FakeTranslation();
    final service = TranslationService(
        registry: fakeTranslationRegistry,
        tier: DeviceTier.t2,
        store: fake.store,
        openSpec: (_) async => null,
        brain: fakeBrainStore(secrets: secrets, brain: FakeBrain(const [])));
    final w = await work('en');
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(
            db: db, profileId: profileId, work: w, translation: service)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reader-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('translate-action')));
    await tester.pumpAndSettle();

    expect(find.byKey(better), findsOneWidget);
  });

  testWidgets('once the brain has made all of it, there is nothing to send '
      'and the choice is not offered', (tester) async {
    configureAnthropic();
    final w = await work('en');
    for (final (seg, i, text) in [
      (0, 0, 'Hello there.'),
      (0, 1, 'How are you?'),
      (1, 0, 'Goodbye now.'),
    ]) {
      await db.spineDao.upsertTranslationSentence(
          workId: w.id,
          segmentIdx: seg,
          sentenceIdx: i,
          lang: 'ja',
          sourceText: text,
          body: '良い',
          engine: 'domovoi:byokAnthropic');
    }
    await openSheet(tester, w, brain: FakeBrain(const []));
    expect(find.byKey(better), findsNothing);
  });
}
