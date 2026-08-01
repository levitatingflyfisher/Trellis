import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_screen.dart';

/// The scroll-mode dual display (ADR-0008 "Babel" Phase 3 last slice):
/// "Show Spanish" pairs each translated sentence with the original it came
/// from, visually quiet, without disturbing the word-level tap/seek
/// contract reader_print_test.dart already pins for the untranslated path.
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
      (idx: 0, kind: 'prose', text: 'Hello there. How are you today?'),
    ]);
  });
  tearDown(() => db.close());

  Future<void> openScroll(WidgetTester tester) async {
    final work =
        (await db.spineDao.worksOf(profileId)).firstWhere((w) => w.id == workId);
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(db: db, profileId: profileId, work: work)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mode-toggle')));
    await tester.pumpAndSettle();
  }

  testWidgets('Show Spanish off (the default): no translation text renders, '
      'even with rows stored', (tester) async {
    await db.spineDao.upsertTranslationSentence(
        workId: workId,
        segmentIdx: 0,
        sentenceIdx: 0,
        lang: 'es',
        sourceText: 'Hello there.',
        body: 'Hola.');
    await openScroll(tester);
    expect(find.text('Hola.'), findsNothing);
    // The untouched path: every word still renders as its own tappable
    // text (reader_print_test.dart's structural contract). 'Hello' itself
    // is the work's opening word and renders as a split drop cap, not a
    // plain Text — 'there.' is the next word along.
    expect(find.text('there.'), findsOneWidget);
  });

  testWidgets('Show Spanish on: a translated sentence shows its Spanish '
      'text; a sentence with no stored row shows English only', (tester) async {
    await db.spineDao.upsertTranslationSentence(
        workId: workId,
        segmentIdx: 0,
        sentenceIdx: 0,
        lang: 'es',
        sourceText: 'Hello there.',
        body: 'Hola.');
    await db.spineDao.setShowTranslationLayer(workId, true);
    await openScroll(tester);

    expect(find.text('Hola.'), findsOneWidget);
    // The second sentence has no stored row — nothing extra renders for
    // it, and its own words are still there.
    expect(find.text('today?'), findsOneWidget);
  });

  testWidgets('a stale row (source text no longer matches) never renders — '
      'falls back to English silently', (tester) async {
    await db.spineDao.upsertTranslationSentence(
        workId: workId,
        segmentIdx: 0,
        sentenceIdx: 0,
        lang: 'es',
        sourceText: 'A completely different sentence.',
        body: 'Hola.');
    await db.spineDao.setShowTranslationLayer(workId, true);
    await openScroll(tester);

    expect(find.text('Hola.'), findsNothing);
  });

  testWidgets('word tap-to-seek still resolves the correct global word '
      'index under dual display — the cursor law is untouched by the '
      'overlay', (tester) async {
    await db.spineDao.upsertTranslationSentence(
        workId: workId,
        segmentIdx: 0,
        sentenceIdx: 0,
        lang: 'es',
        sourceText: 'Hello there.',
        body: 'Hola.');
    await db.spineDao.setShowTranslationLayer(workId, true);
    await openScroll(tester);

    // Tap a word in the SECOND sentence; the cursor must land exactly on
    // it, proving the per-sentence Wrap split didn't shift word indices.
    await tester.tap(find.text('today?'));
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('cursor-word'))).data,
        'today?');
  });

  testWidgets('the drop cap still renders on the work\'s opening word under '
      'dual display', (tester) async {
    await db.spineDao.setShowTranslationLayer(workId, true);
    await openScroll(tester);
    expect(find.byKey(const Key('drop-cap')), findsOneWidget);
  });
}
