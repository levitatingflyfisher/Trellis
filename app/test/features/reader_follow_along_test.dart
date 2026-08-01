import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/main.dart';

/// Campaign 4 Phase 2: follow-along guided pacing for scroll mode — the
/// speak-mode karaoke path (per-segment GlobalKeys + Scrollable.
/// ensureVisible, borrowed from karaoke_screen.dart's _followPlayback,
/// since no auto-scroll of any kind existed anywhere in reader_screen.dart
/// before this) driven by the SAME cursor/timer RSVP already uses
/// (_wordIdx/_step/_play/_pause), not a second highlighter or a second
/// dwell path. Reuses the existing cursor-word highlight
/// (`reader_screen.dart`'s `Key('cursor-word')`) untouched.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<int> seedMultiSegment(String title) async {
    final profileId = await db.profilesDao.create('Ada');
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'note',
        title: title,
        persistence: 'work',
        firstSeenEpochDay: 100,
        lang: 'en');
    await db.spineDao.insertSegments(workId, [
      for (var i = 0; i < 8; i++)
        (idx: i, kind: 'prose', text: 'Paragraph number $i has a few words.')
    ]);
    return profileId;
  }

  /// Campaign 9 Phase 6: `mode-toggle` now opens a labeled three-way
  /// picker (Scroll / Words / Lines) rather than cycling on its own tap —
  /// [itemKey] names the destination explicitly (`mode-item-words`,
  /// `mode-item-scroll`, `mode-item-lines`).
  Future<void> switchMode(WidgetTester tester, String itemKey) async {
    await tester.tap(find.byKey(const Key('mode-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key(itemKey)));
    await tester.pumpAndSettle();
  }

  Future<void> openInScroll(WidgetTester tester, {required String title}) async {
    await tester.pumpWidget(TrellisApp(db: db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
    await switchMode(tester, 'mode-item-scroll');
  }

  /// Stop the shared cursor timer before the test ends — the doc has
  /// plenty of words left, so an un-stopped `_step()` Timer would still be
  /// pending at teardown ("A Timer is still pending even after the widget
  /// tree was disposed"). Only ever called once follow-along is on, so the
  /// menu always reads "Stop following along" here.
  Future<void> stopFollowing(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('reader-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stop following along'));
    await tester.pumpAndSettle();
  }

  testWidgets('the overflow menu offers Follow along only in scroll mode',
      (tester) async {
    await seedMultiSegment('Along');
    await tester.pumpWidget(TrellisApp(db: db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Along'));
    await tester.pumpAndSettle();
    // Still RSVP mode — no Follow along entry yet.
    await tester.tap(find.byKey(const Key('reader-overflow')));
    await tester.pumpAndSettle();
    expect(find.text('Follow along'), findsNothing);
    // Close the menu without selecting anything.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await switchMode(tester, 'mode-item-scroll');
    await tester.tap(find.byKey(const Key('reader-overflow')));
    await tester.pumpAndSettle();
    expect(find.text('Follow along'), findsOneWidget);
  });

  /// Tap the "Follow along" menu item WITHOUT `pumpAndSettle` — the shared
  /// `_step()` Timer keeps rescheduling itself while playing, so settling
  /// after starting it runs the fake clock all the way to the end of the
  /// document in one call, defeating any test that wants to observe an
  /// INCREMENTAL advance. A bounded pump is enough for the popup's own
  /// dismiss animation.
  Future<void> startFollowing(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('reader-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Follow along'));
    await tester.pump(const Duration(milliseconds: 300));
  }

  String? cursorWordText(WidgetTester tester) {
    final finder = find.byKey(const Key('cursor-word'));
    if (finder.evaluate().isEmpty) return null;
    return tester.widget<Text>(finder).data;
  }

  testWidgets(
      'follow along reuses _wordIdx/_play — the cursor-word highlight moves',
      (tester) async {
    await seedMultiSegment('Along');
    await openInScroll(tester, title: 'Along');
    await startFollowing(tester);

    // Word 0 is the drop cap (no `cursor-word` key even while current —
    // see _flowWord); advance once to land on a plain flowing word first.
    await tester.pump(const Duration(milliseconds: 250));
    final earlyWord = cursorWordText(tester);
    expect(earlyWord, isNotNull);

    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    final laterWord = cursorWordText(tester);
    expect(laterWord, isNot(earlyWord),
        reason: 'the shared cursor advanced under follow-along play');

    await stopFollowing(tester);
  });

  testWidgets('the viewport actually scrolls to follow the cursor across a '
      'segment boundary', (tester) async {
    await seedMultiSegment('Along');
    await openInScroll(tester, title: 'Along');

    final scrollable = find.byType(Scrollable).first;
    final before = tester.state<ScrollableState>(scrollable).position.pixels;

    await startFollowing(tester);

    // Each seeded segment is short (a handful of words) — well under 20
    // dwells crosses several segment boundaries at the default wpm.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    final after = tester.state<ScrollableState>(scrollable).position.pixels;
    expect(after, greaterThan(before),
        reason: 'ensureVisible followed the cursor into later segments');

    await stopFollowing(tester);
  });

  testWidgets('a manual tap-to-seek pauses nothing on its own, but the '
      'follow-along toggle itself is a pause/resume switch',
      (tester) async {
    await seedMultiSegment('Along');
    await openInScroll(tester, title: 'Along');
    await startFollowing(tester);
    // Off the drop cap so cursor-word exists to compare against below.
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.byKey(const Key('reader-overflow')));
    await tester.pumpAndSettle();
    expect(find.text('Stop following along'), findsOneWidget);
    await tester.tap(find.text('Stop following along'));
    // Stopping cancels the Timer outright — nothing left to run away with,
    // so settling here is safe.
    await tester.pumpAndSettle();

    final word = cursorWordText(tester);
    await tester.pump(const Duration(seconds: 2));
    final wordAfterPause = cursorWordText(tester);
    expect(wordAfterPause, word,
        reason: 'stopping follow-along actually stops the shared timer');
  });

  testWidgets('long-pressing a word during follow-along pauses the cursor '
      '— the dictionary sheet must not compete with an advancing document',
      (tester) async {
    await seedMultiSegment('Along');
    await openInScroll(tester, title: 'Along');
    await startFollowing(tester);
    // Off the drop cap so cursor-word exists to compare against below.
    await tester.pump(const Duration(milliseconds: 250));

    // tester.longPress itself pumps ~500ms of virtual time to register the
    // gesture — the shared _step Timer keeps running during that window
    // (it's only cancelled once _openDefinitionSheet's callback fires), so
    // the word the cursor lands on right as the sheet opens, NOT the word
    // captured before the press, is the correct baseline for "did it move
    // AFTER this."
    await tester.longPress(find.text('number').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('dictionary-sheet')), findsOneWidget);
    final wordAtSheetOpen = cursorWordText(tester);
    expect(wordAtSheetOpen, isNotNull);

    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    final wordWhileSheetOpen = cursorWordText(tester);
    expect(wordWhileSheetOpen, wordAtSheetOpen,
        reason: 'opening the definition sheet paused the shared timer '
            'instead of letting it race an ensureVisible call underneath '
            'a modal route');

    await tester.tap(find.byKey(const Key('definition-sheet-close')));
    await tester.pumpAndSettle();
  });
}
