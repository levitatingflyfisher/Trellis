import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/profiles/parent_pin.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/scripted_fetcher.dart';

/// The one PIN chokepoint (P5). What the PIN gates: profile create/delete/
/// rename and the parent dashboard. What it NEVER gates: reading, playing,
/// studying — a kid can always use their own profile (ADR-0003; sovereignty
/// is for the reader too).
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((u, h) => textResponse('')),
        createPlayer: FakeEpisodePlayer.new));
    await tester.pumpAndSettle();
  }

  testWidgets('kids can always read: picking a profile never asks for a PIN',
      (tester) async {
    await db.profilesDao.create('Ada');
    await db.profilesDao.create('Grace');
    await ParentPinService(db).enable('1234');
    await pumpApp(tester);

    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pin-entry')), findsNothing);
    expect(find.text('Library'), findsWidgets, reason: 'straight to the '
        'shell — reading is never locked');
  });

  testWidgets('without a PIN the parent dashboard door opens directly',
      (tester) async {
    await db.profilesDao.create('Ada');
    await pumpApp(tester);

    await tester.tap(find.text('Parent dashboard'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pin-entry')), findsNothing);
    expect(find.text('What each reader has built.'), findsOneWidget);
  });

  testWidgets('with a PIN the dashboard demands it; a wrong PIN stays out',
      (tester) async {
    await db.profilesDao.create('Ada');
    await ParentPinService(db).enable('1234');
    await pumpApp(tester);

    await tester.tap(find.text('Parent dashboard'));
    await tester.pumpAndSettle();

    // The gate, with the honest forgotten-PIN truth in it.
    expect(find.byKey(const Key('pin-entry')), findsOneWidget);
    expect(find.textContaining('no recovery'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('pin-entry')), '9999');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.textContaining("not the PIN"), findsOneWidget);
    expect(find.text('What each reader has built.'), findsNothing);

    await tester.enterText(find.byKey(const Key('pin-entry')), '1234');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.text('What each reader has built.'), findsOneWidget);
  });

  testWidgets('"Add a reader" is PIN-gated once a PIN exists',
      (tester) async {
    await db.profilesDao.create('Ada');
    await ParentPinService(db).enable('1234');
    await pumpApp(tester);

    await tester.tap(find.text('Add a reader'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pin-entry')), findsOneWidget);
    expect(find.byKey(const Key('profile-name')), findsNothing);

    await tester.enterText(find.byKey(const Key('pin-entry')), '1234');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profile-name')), findsOneWidget);
  });

  testWidgets('without a PIN, "Add a reader" opens directly', (tester) async {
    await db.profilesDao.create('Ada');
    await pumpApp(tester);

    await tester.tap(find.text('Add a reader'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pin-entry')), findsNothing);
    expect(find.byKey(const Key('profile-name')), findsOneWidget);
  });

  testWidgets('first run is untouched: no profiles, no PIN, straight to '
      'creating a reader', (tester) async {
    await pumpApp(tester);
    expect(find.byKey(const Key('profile-name')), findsOneWidget);
    expect(find.byKey(const Key('pin-entry')), findsNothing);
  });
}
