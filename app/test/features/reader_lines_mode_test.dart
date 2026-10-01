import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_prefs.dart';
import 'package:trellis/features/reader/reader_screen.dart';
import 'package:trellis/main.dart';
import '../support/pick_reader.dart';
import '../support/tabs.dart';
import '../support/open_work.dart';

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
    await pickReader(tester, 'Ada');
    await toTab(tester, 'Library');
    await openToRead(tester, title);
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

  // 1.5.5 user ruling: two modes, RSVP and Page, and Page's highlight —
  // every option offered at phone width too, never gated by screen size.
  testWidgets('the picker offers RSVP and Page, and Page highlights Follow '
      'along and Line, at 320dp', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await seedMultiSegment('Along');
    await openReader(tester, title: 'Along');

    await tester.tap(find.byKey(const Key('mode-toggle')));
    await tester.pumpAndSettle();

    // The bar's face may name the current mode too.
    expect(find.text('RSVP'), findsWidgets);
    expect(find.text('Page'), findsOneWidget);
    expect(find.text('Follow along'), findsOneWidget);
    expect(find.text('Line'), findsOneWidget);
    expect(find.text('Scroll'), findsNothing);
    expect(find.text('Words'), findsNothing);
    expect(
        find.text('Rapid serial visual presentation: one word at a time, '
            'eyes still (foveal reading).'),
        findsOneWidget);
    final rsvpItem = tester.widget<CheckedPopupMenuItem<ReaderMode>>(
        find.byKey(const Key('mode-item-rsvp')));
    expect(rsvpItem.checked, isTrue);

    await tester.tapAt(const Offset(10, 10)); // dismiss without selecting
    await tester.pumpAndSettle();
  });

  for (final (wire, highlight) in [
    ('scroll', 'highlight-item-follow'),
    ('lines', 'highlight-item-line'),
  ]) {
    testWidgets('a reader saved in "$wire" opens on Page with $highlight',
        (tester) async {
      final profileId = await seedMultiSegment('Along');
      await db.profilesDao.setReaderPrefs(
          profileId, ReaderPrefs(session: ReaderSession(mode: wire)));
      await openReader(tester, title: 'Along');
      expect(
          find.descendant(
              of: find.byKey(const Key('mode-toggle')),
              matching: find.text('Page')),
          findsOneWidget);
      await tester.tap(find.byKey(const Key('mode-toggle')));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<CheckedPopupMenuItem<ReaderMode>>(find.byKey(Key(highlight)))
              .checked,
          isTrue);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
    });
  }

  testWidgets(
      'the cursor survives a round trip through Lines mode, both '
      'directions (ADR-0002)', (tester) async {
    await seedMultiSegment('Along');
    await openReader(tester, title: 'Along');

    await tapZone(tester, 5 / 6);
    await tapZone(tester, 5 / 6);
    final before = rsvpWord(tester);

    await switchMode(tester, 'highlight-item-line');
    await switchMode(tester, 'mode-item-rsvp');

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

    await switchMode(tester, 'highlight-item-line');

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
}
