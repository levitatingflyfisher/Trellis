import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhearth_design/openhearth_design.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/settings/theme_preference.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/scripted_fetcher.dart';
import '../support/pick_reader.dart';
import '../support/tabs.dart';

/// Fleet ruling: light, dark or follow the phone; default follow the
/// phone; reachable in two taps from every primary screen. Trellis never
/// stored a theme before, so there is nothing to migrate: the cases are
/// the default, a round-trip, and an unknown stored value.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('default is follow the phone', () async {
    expect(await ThemePreferenceController.read(db),
        OhThemeModePreference.system);
  });

  test('a stored choice round-trips', () async {
    final c = ThemePreferenceController(db);
    await c.choose(OhThemeModePreference.dark);
    expect(await ThemePreferenceController.read(db),
        OhThemeModePreference.dark);
  });

  test('an unknown stored value falls back to follow the phone', () async {
    await db.deviceSettingsDao
        .write(ThemePreferenceController.storageKey, 'sepia');
    expect(await ThemePreferenceController.read(db),
        OhThemeModePreference.system);
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((u, h) => textResponse('')),
        createPlayer: () => FakeEpisodePlayer()));
    await tester.pumpAndSettle();
  }

  ThemeMode appMode(WidgetTester tester) =>
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode!;

  // The app-bar "Auto" button read as a mystery until tapped (user: "I
  // clicked it to learn it was about dark mode"), and a worded item that
  // opened a chooser made it three taps. The fleet ruling is one or two:
  // the three named choices sit in each tab's menu, the one in use checked.
  for (final tab in ['Latest', 'Queue', 'Library', 'Courses']) {
    testWidgets('$tab: dark is two taps from the menu, and sticks',
        (tester) async {
      await db.profilesDao.create('Ada');
      await pumpApp(tester);
      await pickReader(tester, 'Ada');
      await toTab(tester, tab);
      expect(appMode(tester), ThemeMode.system);
      expect(find.byKey(const Key('theme-toggle')), findsNothing,
          reason: 'no unexplained theme button on the bar');

      Future<void> openMenu() async {
        await tester.tap(find.descendant(
            of: find.byType(AppBar), matching: find.byIcon(Icons.more_vert)));
        await tester.pumpAndSettle();
      }

      bool checked(String label) => tester
          .widget<CheckedPopupMenuItem<String>>(
              find.widgetWithText(CheckedPopupMenuItem<String>, label))
          .checked;

      await openMenu();
      expect(find.text('Theme'), findsOneWidget, reason: 'the group says what it is');
      expect(checked('Follow phone'), isTrue);
      expect(checked('Light'), isFalse);
      expect(checked('Dark'), isFalse);
      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();

      expect(appMode(tester), ThemeMode.dark);
      expect(await ThemePreferenceController.read(db),
          OhThemeModePreference.dark);
      await openMenu();
      expect(checked('Dark'), isTrue);
      expect(checked('Follow phone'), isFalse);
    });
  }

  testWidgets('a stored choice is applied at launch', (tester) async {
    await db.deviceSettingsDao
        .write(ThemePreferenceController.storageKey, 'light');
    await pumpApp(tester);
    expect(appMode(tester), ThemeMode.light);
  });

  test('the pre-frame read never holds the first frame: a hung or failing '
      'read gives null within the deadline', () async {
    final hung = Completer<int>();
    final sw = Stopwatch()..start();
    expect(await withinDeadline(() => hung.future,
        const Duration(milliseconds: 50)), isNull);
    expect(sw.elapsedMilliseconds, lessThan(1000));
    expect(await withinDeadline<int>(() async => throw StateError('x'),
        const Duration(milliseconds: 50)), isNull);
    expect(await ThemePreferenceController.readBeforeFirstFrame(db),
        OhThemeModePreference.system);
  });
}
