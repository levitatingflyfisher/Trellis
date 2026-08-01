import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_prefs.dart';
import 'package:trellis/features/reader/reader_typography_settings_screen.dart';

/// Campaign 4 Phase 1: the typography settings surface itself — sliders and
/// a stepper that write [ReaderPrefs] as they move, plus a live preview
/// paragraph that renders the CURRENT values (ergonomic-ux: show, don't
/// just tell).
void main() {
  late AppDatabase db;
  late int profileId;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
  });
  tearDown(() => db.close());

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
        home: ReaderTypographySettingsScreen(db: db, profileId: profileId)));
    await tester.pumpAndSettle();
  }

  testWidgets('opens showing the donor defaults in the live preview',
      (tester) async {
    await open(tester);
    final preview =
        tester.widget<Text>(find.byKey(const Key('typography-preview')));
    expect(preview.style?.fontFamily, 'Lora');
    expect(preview.style?.height, 1.6);
  });

  testWidgets('moving the font-scale slider updates the preview and persists',
      (tester) async {
    await open(tester);
    final slider =
        tester.widget<Slider>(find.byKey(const Key('fontscale-slider')));
    expect(slider.value, 1.0);

    // Invoke the callback directly — deterministic, no pixel-accurate drag.
    slider.onChanged!(1.5);
    await tester.pump();

    final preview =
        tester.widget<Text>(find.byKey(const Key('typography-preview')));
    expect(preview.style?.fontSize,
        closeTo(Theme.of(tester.element(find.byType(MaterialApp)))
                .textTheme
                .bodyLarge!
                .fontSize! *
            1.5,
        0.01));

    final saved = await db.profilesDao.readerPrefs(profileId);
    expect(saved.typography.fontScale, 1.5);
  });

  testWidgets('picking Nunito persists and updates the preview',
      (tester) async {
    await open(tester);
    await tester.tap(find.text('Nunito'));
    await tester.pump();

    final preview =
        tester.widget<Text>(find.byKey(const Key('typography-preview')));
    expect(preview.style?.fontFamily, 'Nunito');
    final saved = await db.profilesDao.readerPrefs(profileId);
    expect(saved.typography.typeface, ReaderTypeface.nunito);
  });

  testWidgets('the justified toggle is off by default and names its own honesty',
      (tester) async {
    await open(tester);
    final toggle =
        tester.widget<SwitchListTile>(find.byKey(const Key('justified-switch')));
    expect(toggle.value, isFalse);
    expect(find.textContaining('wide gaps'), findsOneWidget);

    await tester.tap(find.byKey(const Key('justified-switch')));
    await tester.pump();
    final saved = await db.profilesDao.readerPrefs(profileId);
    expect(saved.typography.justified, isTrue);
  });

  testWidgets('the paragraph-spacing stepper is 48dp and persists a step up',
      (tester) async {
    await open(tester);
    final stepper = tester.getSize(find.byKey(const Key('paragraphspacing-up')));
    expect(stepper.height, greaterThanOrEqualTo(48));
    expect(stepper.width, greaterThanOrEqualTo(48));

    await tester.tap(find.byKey(const Key('paragraphspacing-up')));
    await tester.pump();
    final saved = await db.profilesDao.readerPrefs(profileId);
    expect(saved.typography.paragraphSpacing, greaterThan(8));
  });

  testWidgets('the whole screen survives 320dp at 2x text scale',
      (tester) async {
    // The fleet's recurring accessibility wound (narrow_screen_test.dart)
    // doesn't visit this screen — it's new this campaign. The typeface
    // picker's Row (a fixed-width label beside an Expanded SegmentedButton)
    // and the paragraph-spacing stepper's Row (48dp IconButtons either
    // side of an unconstrained "Ndp" Text) are exactly the rigid-Row shape
    // that overflows at large text scale on narrow screens, so this is a
    // real check, not a formality.
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);

    await open(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editing typography never clobbers a lastPlayedWorkId already '
      'in the SAME shared prefs blob (Campaign 9 Phase 2)', (tester) async {
    await db.profilesDao.setReaderPrefs(
        profileId, const ReaderPrefs(lastPlayedWorkId: 42));

    await open(tester);
    final slider =
        tester.widget<Slider>(find.byKey(const Key('fontscale-slider')));
    slider.onChanged!(1.5);
    await tester.pump();

    final saved = await db.profilesDao.readerPrefs(profileId);
    expect(saved.typography.fontScale, 1.5);
    expect(saved.lastPlayedWorkId, 42,
        reason: 'this screen only ever meant to touch typography — '
            'writing a bare ReaderPrefs(typography: next) would silently '
            "wipe the player's own key in the same blob");
  });
}
