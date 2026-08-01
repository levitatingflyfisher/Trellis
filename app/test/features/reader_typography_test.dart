import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_prefs.dart';
import 'package:trellis/main.dart';

/// Campaign 4 Phase 1: per-profile typography prefs reach the print
/// reader's rendered paragraph (scroll mode). RSVP/the ticker are untouched
/// — this whole test lives on the scroll side of the mode toggle.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<(int, int)> seed(String text, {String title = 'Typography'}) async {
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

  Future<void> openReaderInScroll(WidgetTester tester,
      {String title = 'Typography'}) async {
    await tester.pumpWidget(TrellisApp(db: db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
    // Campaign 9 Phase 6: `mode-toggle` opens a labeled three-way picker
    // rather than cycling on its own tap.
    await tester.tap(find.byKey(const Key('mode-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mode-item-scroll')));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'font scale, line height and typeface reach a plain word in the '
      'print body', (tester) async {
    final (profileId, _) = await seed('Zero One Two Three.');
    await db.profilesDao.setReaderPrefs(
        profileId,
        const ReaderPrefs(
            typography: ReaderTypography(
                fontScale: 1.25,
                lineHeight: 2.0,
                typeface: ReaderTypeface.nunito)));
    await openReaderInScroll(tester);

    // 'Zero' (word 0) is the drop cap; 'One' is a plain flowing word.
    final word = tester.widget<Text>(find.text('One'));
    expect(word.style?.fontFamily, 'Nunito');
    expect(word.style?.height, 2.0);
    final base = Theme.of(tester.element(find.text('One')))
        .textTheme
        .bodyLarge!
        .fontSize!;
    expect(word.style?.fontSize, closeTo(base * 1.25, 0.001));
  });

  testWidgets('the default typeface is still the donor Lora at 1.6 height',
      (tester) async {
    final (_, _) = await seed('Zero One Two Three.');
    await openReaderInScroll(tester);
    final word = tester.widget<Text>(find.text('One'));
    expect(word.style?.fontFamily, 'Lora');
    expect(word.style?.height, 1.6);
  });

  testWidgets('max text width reaches the print column', (tester) async {
    final (profileId, _) = await seed('Zero One Two Three.');
    await db.profilesDao.setReaderPrefs(profileId,
        const ReaderPrefs(typography: ReaderTypography(maxTextWidth: 480)));
    await openReaderInScroll(tester);

    final column =
        tester.widget<ConstrainedBox>(find.byKey(const Key('print-column')));
    expect(column.constraints.maxWidth, 480);
  });

  testWidgets('paragraph spacing widens a block\'s vertical padding',
      (tester) async {
    final (profileId, _) = await seed('Zero One Two Three.');
    await db.profilesDao.setReaderPrefs(profileId,
        const ReaderPrefs(typography: ReaderTypography(paragraphSpacing: 24)));
    await openReaderInScroll(tester);

    final tile = tester.widget<Container>(find.byKey(const Key('segment-tile-0')));
    final padding = tile.padding as EdgeInsets;
    // The reader's existing 8dp base plus the extra the profile asked for.
    expect(padding.top, 32);
    expect(padding.bottom, 32);
  });

  testWidgets('justified alignment reaches the Wrap; ragged-right is default',
      (tester) async {
    final (profileId, _) = await seed('Zero One Two Three.');
    await openReaderInScroll(tester);
    var wrap = tester.widget<Wrap>(find.byType(Wrap).first);
    expect(wrap.alignment, WrapAlignment.start);

    await db.profilesDao.setReaderPrefs(
        profileId, const ReaderPrefs(typography: ReaderTypography(justified: true)));
    // Reopen (prefs are loaded once, in _load): back pops straight to the
    // library screen already showing this title — re-pumping the whole
    // app here would reuse the Navigator's element and skip its own
    // initState, so re-enter through the same live tree instead.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Typography'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mode-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mode-item-scroll')));
    await tester.pumpAndSettle();
    wrap = tester.widget<Wrap>(find.byType(Wrap).first);
    expect(wrap.alignment, WrapAlignment.spaceBetween);
  });

  testWidgets('the overflow menu opens the reading-style settings screen',
      (tester) async {
    await seed('Zero One Two Three.');
    await openReaderInScroll(tester);

    await tester.tap(find.byKey(const Key('reader-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reading style'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('reader-typography-settings-screen')),
        findsOneWidget);
  });
}
