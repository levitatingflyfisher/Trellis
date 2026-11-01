import 'dart:io';
import 'dart:math' as math;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/app_version.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/settings/settings_screen.dart';
import 'package:trellis/main.dart';

import '../../support/fake_player.dart';
import '../../support/fake_services.dart';
import '../../support/pick_reader.dart';
import '../../support/scripted_fetcher.dart';
import '../../support/tabs.dart';

/// Board-0131/0132 (owner: "I still am annoyed by the three dots hiding
/// different things on different screens"): every app-wide thing is in
/// one Settings screen, behind a fifth bottom-bar item that is always
/// there.
void main() {
  late Directory dir;
  late AppDatabase db;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('trellis-settings-tab');
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await db.profilesDao.create('Ada');
    final player = FakeEpisodePlayer();
    await tester.pumpWidget(
      TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((u, h) => textResponse('')),
        createPlayer: () => player,
        services: testServices(dir),
      ),
    );
    await tester.pumpAndSettle();
    await pickReader(tester, 'Ada');
  }

  List<String> barLabels(WidgetTester tester) => [
    for (final d in tester.widgetList<NavigationDestination>(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.byType(NavigationDestination),
      ),
    ))
      d.label,
  ];

  // The owner's order (12 Nov): "Subscriptions, Latest, Queue, Library,
  // Courses, and then settings".
  const tabs = [
    'Subs',
    'Latest',
    'Queue',
    'Library',
    'Courses',
    'Settings',
  ];

  testWidgets('the bottom bar has the same six items on every tab, in the '
      'owner’s order, and Settings opens the Settings screen', (tester) async {
    await pumpApp(tester);
    for (final tab in tabs) {
      await toTab(tester, tab);
      expect(barLabels(tester), tabs, reason: 'on $tab');
    }
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('Settings')),
      findsOneWidget,
    );
  });

  testWidgets('Subscriptions is the first tab, a root with no back arrow; '
      'Latest and the Library no longer carry its door', (tester) async {
    await pumpApp(tester);
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('Latest')),
      findsOneWidget,
      reason: 'the app still opens on Latest',
    );
    expect(find.byKey(const Key('manage-feeds')), findsNothing);
    await toTab(tester, 'Library');
    expect(find.byKey(const Key('library-subscriptions')), findsNothing);
    await toTab(tester, 'Subs');
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Subscriptions'),
      ),
      findsOneWidget,
    );
    expect(find.byType(BackButton), findsNothing);
  });

  testWidgets('Settings holds every app-wide item, grouped, each with its '
      'own row', (tester) async {
    await pumpApp(tester);
    await toTab(tester, 'Settings');

    final missing = [
      for (final key in _homes)
        if (find.byKey(key, skipOffstage: false).evaluate().isEmpty) '$key',
    ];
    expect(missing, isEmpty);
    for (final heading in [
      'Theme',
      'Reading',
      'Listening',
      'Learning',
      'Storage and backup',
      'This reader',
      'About',
    ]) {
      expect(
        find.text(heading, skipOffstage: false),
        findsOneWidget,
        reason: heading,
      );
    }
    expect(
      find.text('Trellis $appVersion', skipOffstage: false),
      findsOneWidget,
    );
  });

  // Six items share the width: at 360 dp each has 60, and at 320 dp 53.
  // The owner (board-0169, 12 Nov): the first label is "Subs", and every
  // label is full size. All six are drawn at one size: the phone's own
  // text size where the widest fits its share, else the largest size at
  // which all six fit. None is drawn smaller than the others.
  for (final (width, scale, phoneSize) in [
    (360.0, 1.0, true),
    (412.0, 1.0, true),
    (320.0, 1.0, true),
    (360.0, 1.3, false),
    (320.0, 1.3, false),
  ]) {
    testWidgets('at ${width.toInt()} dp and text $scale every label shows '
        'whole on one line at the bar’s own size', (tester) async {
      tester.view.physicalSize = Size(width, 700);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      await pumpApp(tester);

      for (final tab in tabs) {
        await toTab(tester, tab);
        final sizes = <double>[];
        for (final label in tabs) {
          final paragraph = tester.renderObject<RenderParagraph>(
            find
                .descendant(
                  of: find.byType(NavigationBar),
                  matching: find.text(label),
                )
                .last,
          );
          if (tab == tabs.first) {
            debugPrint('bar-fit ${width.toInt()} dp at $scale: $label '
                'drawn at ${(paragraph.textScaler.scale(12) / 12).toStringAsFixed(2)}x '
                'in ${paragraph.size.width.toStringAsFixed(1)} dp');
          }
          // The width it needs unwrapped fits the width it was given:
          // one line, nothing cut.
          expect(
            paragraph.getMaxIntrinsicWidth(double.infinity),
            lessThanOrEqualTo(paragraph.size.width + 0.5),
            reason: '$label on $tab',
          );
          expect(paragraph.maxLines ?? 1, 1, reason: '$label on $tab');
          sizes.add(paragraph.textScaler.scale(10) / 10);
          if (phoneSize) {
            expect(sizes.last, closeTo(scale, 0.01),
                reason: '$label is drawn at the phone’s own size');
          }
        }
        expect(sizes.reduce(math.max) - sizes.reduce(math.min),
            lessThan(0.001),
            reason: 'every label at one size on $tab');
        if (!phoneSize) {
          expect(sizes.first, greaterThan(1.0),
              reason: 'large text still draws the bar larger');
        }
      }
      expect(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.byType(Icon),
        ),
        findsNWidgets(tabs.length),
        reason: 'one icon per item, each beside its words',
      );
    });
  }

  testWidgets('a theme picked in Settings is the app’s theme at once', (
    tester,
  ) async {
    await pumpApp(tester);
    await toTab(tester, 'Settings');
    await tester.tap(find.byKey(const Key('theme-choice-dark')));
    await tester.pumpAndSettle();
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
    expect(await db.deviceSettingsDao.read('theme_mode'), isNotNull);
  });

  testWidgets('pages opened from Settings open inside its tab, under the '
      'bottom bar', (tester) async {
    await pumpApp(tester);
    await toTab(tester, 'Settings');
    await tester.ensureVisible(find.byKey(const Key('open-models')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-models')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Models & storage'),
      ),
      findsOneWidget,
    );
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('Open-source licences opens the licence list', (tester) async {
    await pumpApp(tester);
    await toTab(tester, 'Settings');
    final row = find.byKey(const Key('settings-licences'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
  });
}

/// Every app-wide item's home in Settings.
const _homes = [
  Key('theme-choice-system'),
  Key('theme-choice-light'),
  Key('theme-choice-dark'),
  Key('settings-reading-style'),
  Key('settings-read-aloud-voices'),
  Key('speak-citations-toggle'),
  Key('dsp-global-default-toggle'),
  Key('open-headset-keys'),
  Key('learning-language-setting'),
  Key('scheduler-toggle'),
  Key('open-thinking'),
  Key('open-models'),
  Key('open-backup'),
  Key('settings-jobs'),
  Key('profile-switcher'),
  Key('open-echo'),
  Key('settings-version'),
  Key('settings-licences'),
];
