import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_screen.dart';
import '../support/fake_tts.dart';

/// Page's follow along (1.5.5): Page's Play reads a text aloud, and the
/// view follows the spoken cursor — the cursor-word highlight moves and
/// the viewport scrolls with it (Campaign 4 Phase 2's follow-along, now
/// driven by speech rather than a silent pacer; RSVP keeps the pacer).
void main() {
  late AppDatabase db;
  late FakeTtsSpeaker tts;
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tts = FakeTtsSpeaker(utteranceLength: const Duration(milliseconds: 400));
  });
  tearDown(() => db.close());

  const firsts = [
    'Alpha',
    'Bravo',
    'Charlie',
    'Delta',
    'Echo',
    'Foxtrot',
    'Golf',
    'Hotel',
  ];

  Future<Work> seedMultiSegment(String title) async {
    final profileId = await db.profilesDao.create('Ada');
    final workId = await db.spineDao.insertWork(
      profileId: profileId,
      kind: 'note',
      title: title,
      persistence: 'work',
      firstSeenEpochDay: 100,
      lang: 'en',
    );
    await db.spineDao.insertSegments(workId, [
      for (var i = 0; i < 8; i++)
        (
          idx: i,
          kind: 'prose',
          text:
              '${firsts[i]} paragraph number $i has a few more words in '
              'it, enough to fill a line or two of the page at this size.',
        ),
    ]);
    return (await db.spineDao.workById(workId))!;
  }

  Future<void> switchMode(WidgetTester tester, String itemKey) async {
    await tester.tap(find.byKey(const Key('mode-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key(itemKey)));
    await tester.pumpAndSettle();
  }

  Future<void> openReader(WidgetTester tester, Work work) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderScreen(
          db: db,
          profileId: work.profileId,
          work: work,
          tts: tts,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openOnPage(WidgetTester tester) async {
    await openReader(tester, await seedMultiSegment('Along'));
    await switchMode(tester, 'mode-item-page');
  }

  Future<void> startListening(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('reader-play')));
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> stopListening(WidgetTester tester) async {
    if (find.byTooltip('Stop reading').evaluate().isNotEmpty) {
      await tester.tap(find.byKey(const Key('reader-play')));
    }
    await tester.pumpAndSettle();
  }

  String? cursorWordText(WidgetTester tester) {
    final finder = find.byKey(const Key('cursor-word'));
    if (finder.evaluate().isEmpty) return null;
    return tester.widget<Text>(finder).data;
  }

  // A Play that makes sound, visible on Page, not an item behind ⋮. RSVP
  // has its own Play in its controls, so no second one there.
  testWidgets('Page has a Play that reads aloud; RSVP keeps its own', (
    tester,
  ) async {
    await openReader(tester, await seedMultiSegment('Along'));
    expect(find.byKey(const Key('reader-play')), findsNothing);
    expect(find.byKey(const Key('play-toggle')), findsOneWidget);

    expect(find.byKey(const Key('speak-toggle')), findsOneWidget);
    await switchMode(tester, 'mode-item-page');
    expect(find.byKey(const Key('reader-play')), findsOneWidget);
    expect(find.byKey(const Key('speak-toggle')), findsNothing,
        reason: 'Page’s Play already reads aloud; no second Read aloud');
    await startListening(tester);
    expect(tts.utterances, isNotEmpty);
    await stopListening(tester);
  });

  testWidgets('Line highlight has the same Play', (tester) async {
    await openReader(tester, await seedMultiSegment('Along'));
    await switchMode(tester, 'highlight-item-line');
    expect(find.byKey(const Key('reader-play')), findsOneWidget);
  });

  testWidgets('listening moves the cursor-word highlight', (tester) async {
    await openOnPage(tester);
    await startListening(tester);
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }
    final earlyWord = cursorWordText(tester);
    expect(earlyWord, isNotNull);
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(
      cursorWordText(tester),
      isNot(earlyWord),
      reason: 'the shared cursor advanced under speech',
    );
    await stopListening(tester);
  });

  for (final item in ['mode-item-page', 'highlight-item-line']) {
    testWidgets('the viewport scrolls to follow the spoken cursor ($item)', (
      tester,
    ) async {
      await openReader(tester, await seedMultiSegment('Along'));
      await switchMode(tester, item);
      final scrollable = find.byType(Scrollable).first;
      final before = tester.state<ScrollableState>(scrollable).position.pixels;
      await startListening(tester);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 400));
      }
      final after = tester.state<ScrollableState>(scrollable).position.pixels;
      expect(
        after,
        greaterThan(before),
        reason: 'ensureVisible followed the cursor into later segments',
      );
      await stopListening(tester);
    });
  }

  testWidgets('Stop stops the cursor', (tester) async {
    await openOnPage(tester);
    await startListening(tester);
    await tester.pump(const Duration(milliseconds: 900));
    await stopListening(tester);
    final word = cursorWordText(tester);
    await tester.pump(const Duration(seconds: 2));
    expect(cursorWordText(tester), word);
  });

  testWidgets('long-pressing a word stops speech — the dictionary sheet '
      'must not compete with an advancing document', (tester) async {
    await openOnPage(tester);
    await startListening(tester);
    await tester.longPress(find.text('number').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('dictionary-sheet')), findsOneWidget);
    final wordAtSheetOpen = cursorWordText(tester);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(cursorWordText(tester), wordAtSheetOpen);
    await tester.tap(find.byKey(const Key('definition-sheet-close')));
    await tester.pumpAndSettle();
  });
}
