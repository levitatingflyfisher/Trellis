import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_screen.dart';
import 'package:trellis/main.dart';

/// Campaign 9 Phase 6 ("a third way to read"): Lines is a genuine third
/// [ReaderMode] alongside Words (RSVP) and Scroll — a scroll-family view
/// that highlights one VISUAL LINE at a time, advancing on the SAME
/// word-level clock RSVP and Scroll's follow-along already share
/// (`_wordIdx`/`_step`/`_play`/`_pause`), never a second timing formula.
/// This file covers the widget-level join: the picker itself, the cursor
/// law across the new mode (ADR-0002, both directions), the viewport
/// anchor on a direct entry, and follow-along reaching Lines mode the
/// same way it already reaches Scroll. The pure line-grouping geometry
/// underneath is covered separately in reader_line_paced_test.dart.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<int> seedMultiSegment(String title,
      {int count = 8, int wordsPerSegment = 10}) async {
    final profileId = await db.profilesDao.create('Ada');
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'note',
        title: title,
        persistence: 'work',
        firstSeenEpochDay: 100,
        lang: 'en');
    await db.spineDao.insertSegments(workId, [
      for (var i = 0; i < count; i++)
        (
          idx: i,
          kind: 'prose',
          text: wordsPerSegment == 10
              ? 'Paragraph number $i has a few words in it today.'
              : [for (var w = 0; w < wordsPerSegment; w++) 'p${i}w$w']
                  .join(' ')
        )
    ]);
    return profileId;
  }

  Future<void> openReader(WidgetTester tester, {required String title}) async {
    await tester.pumpWidget(TrellisApp(db: db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  Future<void> switchMode(WidgetTester tester, String itemKey) async {
    await tester.tap(find.byKey(const Key('mode-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key(itemKey)));
    await tester.pumpAndSettle();
  }

  Future<void> tapZone(WidgetTester tester, double fraction) async {
    final rect = tester.getRect(find.byKey(const Key('reader-tapzone')));
    await tester.tapAt(
        Offset(rect.left + rect.width * fraction, rect.center.dy));
    await tester.pump();
  }

  String rsvpWord(WidgetTester tester) {
    String at(Key k) => tester.widget<Text>(find.byKey(k)).data!;
    return at(const Key('rsvp-bef')) +
        at(const Key('rsvp-piv')) +
        at(const Key('rsvp-aft'));
  }

  testWidgets(
      'the mode picker offers three labeled choices; Words is checked on '
      'open', (tester) async {
    await seedMultiSegment('Along');
    await openReader(tester, title: 'Along');

    await tester.tap(find.byKey(const Key('mode-toggle')));
    await tester.pumpAndSettle();

    expect(find.text('Scroll'), findsOneWidget);
    expect(find.text('Words'), findsOneWidget);
    expect(find.text('Lines'), findsOneWidget);
    final wordsItem = tester.widget<CheckedPopupMenuItem<ReaderMode>>(
        find.byKey(const Key('mode-item-words')));
    expect(wordsItem.checked, isTrue);

    await tester.tapAt(const Offset(10, 10)); // dismiss without selecting
    await tester.pumpAndSettle();
  });

  testWidgets(
      'the cursor survives a round trip through Lines mode, both '
      'directions (ADR-0002)', (tester) async {
    await seedMultiSegment('Along');
    await openReader(tester, title: 'Along');

    await tapZone(tester, 5 / 6);
    await tapZone(tester, 5 / 6);
    final before = rsvpWord(tester);

    await switchMode(tester, 'mode-item-lines');
    await switchMode(tester, 'mode-item-words');

    expect(rsvpWord(tester), before);
  });

  testWidgets(
      'switching into Lines mode from a deep cursor opens anchored at '
      'that segment, not the top', (tester) async {
    // [_load] itself already anchors a RESTORED position correctly —
    // that is not what this pins. This moves the cursor DEEP via live
    // RSVP navigation, entirely in-session (no reload), so the only
    // thing that can have anchored Lines mode correctly is [_setMode]'s
    // own branch — the exact one the dispatch note flagged as easy to
    // drop in a rebase.
    await seedMultiSegment('Along', count: 60, wordsPerSegment: 2);
    await openReader(tester, title: 'Along');

    for (var i = 0; i < 91; i++) {
      await tapZone(tester, 5 / 6);
    }

    await switchMode(tester, 'mode-item-lines');

    // Word 91 (0-based) sits in segment 45 (2 words/segment) — nowhere
    // near the SliverList's own lazy build-ahead cache from position 0.
    // A dropped (or wrongly-guarded) anchor branch would leave this tile
    // entirely unbuilt, not merely unscrolled-to.
    expect(find.byKey(const Key('segment-tile-45')), findsOneWidget,
        reason: 'the anchor followed the live cursor, the same way '
            'Scroll mode already does');
    expect(find.byKey(const Key('segment-tile-0')), findsNothing,
        reason: 'and the top of the document is nowhere near the '
            'lazily-built window from a segment-45 anchor');
  });

  testWidgets(
      'follow-along also drives Lines mode — the viewport scrolls to '
      'follow the cursor', (tester) async {
    // Short (2-word) segments, many of them, and a long pump budget: the
    // cursor must cross enough segments to outgrow the FIRST viewportful
    // regardless of a mode's own per-block height (Lines runs shorter
    // than Scroll's Wrap — no runSpacing, no drop-cap sizing; see
    // reader_line_paced_test.dart's Stack-sizing check for that
    // distinction in isolation) — otherwise every segment the cursor
    // reaches is already on screen and the assertion below would pass
    // vacuously with nothing actually exercising ensureVisible.
    final profileId = await db.profilesDao.create('Ada');
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'note',
        title: 'Along',
        persistence: 'work',
        firstSeenEpochDay: 100,
        lang: 'en');
    await db.spineDao.insertSegments(workId, [
      for (var i = 0; i < 30; i++) (idx: i, kind: 'prose', text: 'Paragraph $i.')
    ]);

    await openReader(tester, title: 'Along');
    await switchMode(tester, 'mode-item-lines');

    final scrollable = find.byType(Scrollable).first;
    final before = tester.state<ScrollableState>(scrollable).position.pixels;

    await tester.tap(find.byKey(const Key('reader-overflow')));
    await tester.pumpAndSettle();
    expect(find.text('Follow along'), findsOneWidget,
        reason: 'Lines is scroll-family (Campaign 9 Phase 6) — follow-'
            'along is offered here too, not just in Scroll');
    await tester.tap(find.text('Follow along'));
    await tester.pump(const Duration(milliseconds: 300));

    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    final after = tester.state<ScrollableState>(scrollable).position.pixels;
    expect(after, greaterThan(before),
        reason: 'ensureVisible followed the cursor into later segments '
            'in Lines mode too');

    await tester.tap(find.byKey(const Key('reader-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stop following along'));
    await tester.pumpAndSettle();
  });
}
