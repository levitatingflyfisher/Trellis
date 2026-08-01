import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_logic.dart';
import 'package:trellis/main.dart';

/// Campaign 4 Phase 2: the lost priming visuals, restored as first-class
/// reader options (donor OpenHearth/ohPrimer index.html) --
///
/// - the classic-mode ORP anchor fix (a reserved before-pivot width) plus
///   its guide line and tick marks (index.html:177-179, 2659-2666);
/// - Parafoveal mode, an RSVP sub-toggle (not a third [ReaderMode] -- the
///   mode-toggle button cycles a strictly binary rsvp/scroll state today,
///   and both `reader_test.dart`'s and `reader_ticker_test.dart`'s cursor-
///   law tests only exercise those two states; a sub-toggle restores the
///   donor's third display without touching that cycle or those tests).
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<int> seed(String text, {String title = 'Visuals'}) async {
    final profileId = await db.profilesDao.create('Ada');
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'note',
        title: title,
        persistence: 'work',
        firstSeenEpochDay: 100,
        lang: 'en');
    await db.spineDao
        .insertSegments(workId, [(idx: 0, kind: 'prose', text: text)]);
    return profileId;
  }

  Future<void> openReader(WidgetTester tester,
      {String title = 'Visuals'}) async {
    await tester.pumpWidget(TrellisApp(db: db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  group('classic-mode ORP anchor', () {
    testWidgets(
        'the before-pivot span reserves orpBeforeReserve, not just its glyph width',
        (tester) async {
      await seed('wonderful day.');
      await openReader(tester);

      final befBox =
          tester.renderObject<RenderBox>(find.byKey(const Key('rsvp-bef')));
      final style =
          tester.widget<Text>(find.byKey(const Key('rsvp-piv'))).style;
      final fontSize = style!.fontSize!;
      final expectedReserve = orpBeforeReserve('wonderful', fontSize * 0.6);

      expect(befBox.size.width, greaterThanOrEqualTo(expectedReserve - 0.5));
    });

    testWidgets('the guide line and both ticks render in classic mode',
        (tester) async {
      await seed('one two three.');
      await openReader(tester);

      expect(find.byKey(const Key('rsvp-guide')), findsOneWidget);
      expect(find.byKey(const Key('rsvp-tick-top')), findsOneWidget);
      expect(find.byKey(const Key('rsvp-tick-bottom')), findsOneWidget);
    });

    testWidgets('the guide disappears once parafoveal is switched on',
        (tester) async {
      await seed('one two three.');
      await openReader(tester);

      await tester.tap(find.byKey(const Key('parafoveal-toggle')));
      await tester.pump();

      expect(find.byKey(const Key('rsvp-guide')), findsNothing);
    });
  });

  group('Parafoveal (RSVP sub-toggle, never named "ticker")', () {
    testWidgets(
        'the toggle switches the display and its own tooltip is always named Parafoveal',
        (tester) async {
      await seed('one two three.');
      await openReader(tester);

      // The public name is always Parafoveal (handoff #8) — checked
      // against the actual tooltip text, not just its absence, so this
      // assertion could fail if the copy ever drifted.
      expect(find.byTooltip('Parafoveal mode'), findsOneWidget,
          reason: 'classic mode offers to switch TO Parafoveal');
      expect(find.byTooltip('Classic mode'), findsNothing);

      await tester.tap(find.byKey(const Key('parafoveal-toggle')));
      await tester.pump();

      expect(find.byKey(const Key('parafoveal-center')), findsOneWidget);
      expect(find.byKey(const Key('rsvp-bef')), findsNothing,
          reason: 'classic-mode pivot spans are gone once parafoveal is on');
      expect(find.byTooltip('Classic mode'), findsOneWidget,
          reason: 'the toggle now offers the way back');
      expect(find.byTooltip('Parafoveal mode'), findsNothing);
    });

    testWidgets('neighbor words carry the Gaussian opacity/scale by distance',
        (tester) async {
      await seed('alpha bravo charlie delta echo foxtrot golf.');
      await openReader(tester);
      await tester.tap(find.byKey(const Key('parafoveal-toggle')));
      await tester.pump();

      // idx 0 is the focus ('alpha'); +1 neighbor is 'bravo'.
      final neighbor =
          tester.widget<Opacity>(find.byKey(const Key('parafoveal-neighbor-1')));
      expect(neighbor.opacity, closeTo(gaussianOpacity(1, 2.0), 1e-6));
    });

    testWidgets('the sentinel center word stays italic and secondary-colored',
        (tester) async {
      final profileId = await db.profilesDao.create('Ada');
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'note',
          title: 'Sentinel',
          persistence: 'work',
          firstSeenEpochDay: 100,
          lang: 'en');
      await db.spineDao.insertSegments(
          workId, [(idx: 0, kind: 'code', text: 'let x = 1;')]);
      await tester.pumpWidget(TrellisApp(db: db));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ada'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sentinel'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('parafoveal-toggle')));
      await tester.pump();

      final center =
          tester.widget<Text>(find.byKey(const Key('parafoveal-center')));
      expect(center.style?.fontStyle, FontStyle.italic);
    });

    testWidgets('punctuation pause lengthening keeps pacing the shared timer',
        (tester) async {
      // Parafoveal reuses _step()/doc.pacing wholesale -- no separate
      // dwell logic to re-test; this just proves the toggle doesn't stop
      // the existing cursor from advancing under play.
      await seed('One. Two.');
      await openReader(tester);
      await tester.tap(find.byKey(const Key('parafoveal-toggle')));
      await tester.pump();

      String centerText() {
        final center =
            tester.widget<Text>(find.byKey(const Key('parafoveal-center')));
        return center.textSpan?.toPlainText() ?? center.data ?? '';
      }

      expect(centerText(), 'One.');
      await tester.tap(find.byKey(const Key('play-toggle')));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(seconds: 3));
      expect(centerText(), isNot('One.'),
          reason: 'the cursor advanced past the first word under play');
    });

    testWidgets('parafoveal mode plus its sigma slider survive 320dp at 2x',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);

      await seed('alpha bravo charlie delta echo foxtrot golf.');
      await openReader(tester);
      await tester.tap(find.byKey(const Key('parafoveal-toggle')));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('sigma-slider')), findsOneWidget);
    });
  });
}
