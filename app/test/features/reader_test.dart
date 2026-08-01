import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/main.dart';

/// The reader half of the alpha loop: RSVP with the donor ORP pivot,
/// punctuation dwell, the cursor law across mode switches (ADR-0002), and
/// position persistence across close/reopen and app-background.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<(int, int)> seed(String text, {String title = 'Five Words'}) async {
    final profileId = await db.profilesDao.create('Ada');
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'note',
        title: title,
        persistence: 'work',
        firstSeenEpochDay: 100);
    await db.spineDao
        .insertSegments(workId, [(idx: 0, kind: 'prose', text: text)]);
    return (profileId, workId);
  }

  Future<void> openReader(WidgetTester tester,
      {String title = 'Five Words'}) async {
    await tester.pumpWidget(TrellisApp(db: db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  String rsvpWord(WidgetTester tester) {
    String at(Key k) => tester.widget<Text>(find.byKey(k)).data!;
    return at(const Key('rsvp-bef')) +
        at(const Key('rsvp-piv')) +
        at(const Key('rsvp-aft'));
  }

  Future<void> tapZone(WidgetTester tester, double fraction) async {
    final rect = tester.getRect(find.byKey(const Key('reader-tapzone')));
    await tester.tapAt(
        Offset(rect.left + rect.width * fraction, rect.center.dy));
    await tester.pump();
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

  testWidgets('opening the reader renders the first word split at the ORP',
      (tester) async {
    await seed('One two three four five.');
    await openReader(tester);

    // 'One' → orp 1: O | n | e, pivot in the hearth red.
    expect(tester.widget<Text>(find.byKey(const Key('rsvp-bef'))).data, 'O');
    final piv = tester.widget<Text>(find.byKey(const Key('rsvp-piv')));
    expect(piv.data, 'n');
    expect(piv.style?.color, const Color(0xFFA85040));
    expect(tester.widget<Text>(find.byKey(const Key('rsvp-aft'))).data, 'e');
  });

  testWidgets('tap zones step the cursor; play advances after the dwell',
      (tester) async {
    await seed('One two three four five.');
    await openReader(tester);

    await tapZone(tester, 5 / 6);
    expect(rsvpWord(tester), 'two');
    await tapZone(tester, 1 / 6);
    expect(rsvpWord(tester), 'One');

    // Play at the default 300 wpm: a plain word shows for 200ms.
    await tester.tap(find.byKey(const Key('play-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 199));
    expect(rsvpWord(tester), 'One');
    await tester.pump(const Duration(milliseconds: 5));
    expect(rsvpWord(tester), 'two');

    await tester.tap(find.byKey(const Key('play-toggle'))); // pause
    await tester.pump();
  });

  testWidgets('punctuation dwells: a clause end waits 1.2x before advancing',
      (tester) async {
    await seed('Wait; then run.', title: 'Clause');
    await openReader(tester, title: 'Clause');

    await tester.tap(find.byKey(const Key('play-toggle')));
    await tester.pump();
    // 'Wait;' paces 1.2 → 240ms at 300 wpm; the base 200ms is not enough.
    await tester.pump(const Duration(milliseconds: 220));
    expect(rsvpWord(tester), 'Wait;');
    await tester.pump(const Duration(milliseconds: 25));
    expect(rsvpWord(tester), 'then');

    await tester.tap(find.byKey(const Key('play-toggle')));
    await tester.pump();
  });

  testWidgets('mode switch preserves the cursor EXACTLY, both directions',
      (tester) async {
    await seed('One two three four five.');
    await openReader(tester);

    await tapZone(tester, 5 / 6);
    await tapZone(tester, 5 / 6);
    expect(rsvpWord(tester), 'three');

    // → scroll: the same word is the cursor, highlighted in flowing text.
    await switchMode(tester, 'mode-item-scroll');
    expect(
        tester.widget<Text>(find.byKey(const Key('cursor-word'))).data, 'three');

    // Tap a word to move the cursor.
    await tester.tap(find.text('five.'));
    await tester.pump();
    expect(
        tester.widget<Text>(find.byKey(const Key('cursor-word'))).data, 'five.');

    // → Words (RSVP), named explicitly rather than "toggled back" — the
    // picker is a labeled three-way choice, not a binary cycle
    // (Campaign 9 Phase 6): the tapped word is what renders.
    await switchMode(tester, 'mode-item-words');
    expect(rsvpWord(tester), 'five.');
  });

  testWidgets('position survives close and reopen at the exact row',
      (tester) async {
    final (profileId, workId) = await seed('One two three four five.');
    await openReader(tester);

    await tapZone(tester, 5 / 6);
    await tapZone(tester, 5 / 6);
    expect(rsvpWord(tester), 'three');

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    // The cursor law's row: (segmentIdx, wordIdx), nothing else.
    final saved =
        await db.spineDao.position(profileId: profileId, workId: workId);
    expect(saved!.segmentIdx, 0);
    expect(saved.wordIdx, 2);
    expect(saved.lastModality, 'read');

    // A fresh app over the same db reopens the reader at the saved word.
    await tester.pumpWidget(Container(key: UniqueKey()));
    await tester.pumpAndSettle();
    await openReader(tester);
    expect(rsvpWord(tester), 'three');
  });

  testWidgets('going to the background saves the position (lifecycle hook)',
      (tester) async {
    final (profileId, workId) = await seed('One two three four five.');
    await openReader(tester);

    await tapZone(tester, 5 / 6);
    expect(rsvpWord(tester), 'two');

    tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    final saved =
        await db.spineDao.position(profileId: profileId, workId: workId);
    expect(saved!.segmentIdx, 0);
    expect(saved.wordIdx, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  });
}
