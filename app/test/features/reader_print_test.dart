import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/main.dart';

/// The print-like reader (proposal-2 §12): scroll mode reads like a set
/// page — Lora body at a book line height, a centered ~680dp measure on
/// wide screens, and a drop cap on the work's opening word that still
/// answers the reader's hand (tap-to-seek and long-press-to-keep, exactly
/// like any other word). RSVP keeps the heritage red ORP pivot, now set in
/// Lora. The drop cap goes to the opening WORD of the work — headings emit
/// no words, so this is the first word of the first prose segment.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<(int, int)> seed(List<String> passages,
      {String title = 'Print'}) async {
    final profileId = await db.profilesDao.create('Ada');
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'note',
        title: title,
        persistence: 'work',
        firstSeenEpochDay: 100,
        lang: 'en');
    await db.spineDao.insertSegments(workId, [
      for (var i = 0; i < passages.length; i++)
        (idx: i, kind: 'prose', text: passages[i])
    ]);
    return (profileId, workId);
  }

  Future<void> openReader(WidgetTester tester,
      {String title = 'Print'}) async {
    await tester.pumpWidget(TrellisApp(db: db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  /// Campaign 9 Phase 6: `mode-toggle` opens a labeled three-way picker
  /// rather than cycling on its own tap — [itemKey] names the
  /// destination explicitly (`mode-item-words`, `mode-item-scroll`,
  /// `mode-item-lines`).
  Future<void> switchMode(WidgetTester tester, String itemKey) async {
    await tester.tap(find.byKey(const Key('mode-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key(itemKey)));
    await tester.pumpAndSettle();
  }

  Future<void> toScroll(WidgetTester tester) =>
      switchMode(tester, 'mode-item-scroll');

  String rsvpWord(WidgetTester tester) {
    String at(Key k) => tester.widget<Text>(find.byKey(k)).data!;
    return at(const Key('rsvp-bef')) +
        at(const Key('rsvp-piv')) +
        at(const Key('rsvp-aft'));
  }

  testWidgets('scroll prose is set in Lora at a print line height',
      (tester) async {
    await seed(['One two three.']);
    await openReader(tester);
    await toScroll(tester);

    final style = tester.widget<Text>(find.text('two')).style;
    expect(style?.fontFamily, 'Lora');
    expect(style?.height, closeTo(1.6, 0.05));
  });

  testWidgets('the drop cap sits on the opening word only, outsized in Lora',
      (tester) async {
    await seed(['One two three.', 'Second segment flows on.']);
    await openReader(tester);
    await toScroll(tester);

    // Exactly one cap in the whole work.
    expect(find.byKey(const Key('drop-cap')), findsOneWidget);
    final cap = tester.widget<Text>(find.byKey(const Key('drop-cap')));
    expect(cap.data, 'O');
    expect(cap.style?.fontFamily, 'Lora');
    final body = tester.widget<Text>(find.text('two')).style;
    expect(cap.style!.fontSize!, greaterThan(body!.fontSize!),
        reason: 'a drop cap is outsized against the body face');

    // The remainder of the word flows on beside the cap…
    expect(find.text('ne'), findsOneWidget);
    expect(find.text('One'), findsNothing);
    // …and the second segment's opener is an ordinary word.
    expect(find.text('Second'), findsOneWidget);
  });

  testWidgets('the drop-cap word still answers the hand: long-press keeps '
      'it in the ledger, tap seeks the cursor to it', (tester) async {
    final (profileId, workId) = await seed(['One two three.']);
    await openReader(tester);
    await toScroll(tester);

    // Long-press → the definition sheet (Campaign 4 Phase 3); its own
    // keep button reaches the ledger, cleaned, with the calm snackbar.
    await tester.longPress(find.byKey(const Key('drop-cap')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('definition-sheet-keep')));
    await tester.pumpAndSettle();
    final rows = await db.ledgerDao.wordsOf(profileId);
    expect(rows.single.word, 'One');
    expect(rows.single.sourceWorkId, workId);
    expect(find.text('“One” is in your word ledger.'), findsOneWidget);

    // Move the cursor away, then tap the cap word: the cursor comes back.
    await tester.tap(find.text('three.'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('drop-cap')));
    await tester.pump();
    await switchMode(tester, 'mode-item-words'); // → RSVP
    expect(rsvpWord(tester), 'One');
  });

  testWidgets('a wide screen sets the page as a centered, constrained column',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await seed(['One two three.']);
    await openReader(tester);
    await toScroll(tester);

    final rect = tester.getRect(find.byKey(const Key('print-column')));
    expect(rect.width, lessThanOrEqualTo(680));
    expect(rect.center.dx, moreOrLessEquals(500, epsilon: 1),
        reason: 'the measure is centered on wide screens');
  });

  testWidgets('the RSVP word is set in Lora and keeps the heritage pivot',
      (tester) async {
    await seed(['One two three.']);
    await openReader(tester);

    final bef = tester.widget<Text>(find.byKey(const Key('rsvp-bef')));
    final piv = tester.widget<Text>(find.byKey(const Key('rsvp-piv')));
    expect(bef.style?.fontFamily, 'Lora');
    expect(piv.style?.fontFamily, 'Lora');
    // The pivot law, untouched: the heritage hearth red.
    expect(piv.style?.color, const Color(0xFFA85040));
  });
}
