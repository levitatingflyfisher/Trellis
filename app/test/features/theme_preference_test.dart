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

/// Fleet ruling: light, dark or follow the phone; default follow the
/// phone; one tap, at most two, from every primary screen. Trellis never
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

  for (final tab in ['Library', 'Courses', 'Inbox']) {
    testWidgets('$tab: dark is two taps away, and it sticks', (tester) async {
      await db.profilesDao.create('Ada');
      await pumpApp(tester);
      await pickReader(tester, 'Ada');
      if (tab != 'Library') {
        await tester.tap(find.text(tab).last);
        await tester.pumpAndSettle();
      }
      expect(appMode(tester), ThemeMode.system);

      await tester.tap(find.byKey(const Key('theme-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dark').last);
      await tester.pumpAndSettle();

      expect(appMode(tester), ThemeMode.dark);
      expect(await ThemePreferenceController.read(db),
          OhThemeModePreference.dark);
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
