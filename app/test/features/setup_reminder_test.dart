import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/backup/backup_custody.dart';
import 'package:trellis/main.dart';
import 'package:trellis/services/device_services.dart';

import '../support/fake_player.dart';
import '../support/scripted_fetcher.dart';
import '../support/pick_reader.dart';

/// Operator ruling 48: unfinished setup is never forgotten. Until this
/// app's recovery phrase is confirmed (and kept), a persistent but
/// dismissible "finish setup" line sits above the tabs; it goes away when
/// the phrase is kept or the user dismisses it, and a dismissal survives a
/// restart.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  final reminder = find.byKey(const Key('setup-reminder'));

  Future<void> openShell(WidgetTester tester, BackupCustody? custody) async {
    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((u, h) => textResponse('')),
        createPlayer: () => FakeEpisodePlayer(),
        services: DeviceServices.detached(backupCustody: custody)));
    await tester.pumpAndSettle();
    await pickReader(tester, 'Ada');
  }

  testWidgets('shown on every tab until the phrase is saved', (tester) async {
    await openShell(tester, MemoryBackupCustody());
    expect(reminder, findsOneWidget);
    expect(
        find.descendant(
            of: reminder,
            matching: find.textContaining('save your recovery phrase')),
        findsOneWidget);
    await tester.tap(find.text('Inbox'));
    await tester.pumpAndSettle();
    expect(reminder, findsOneWidget);
  });

  testWidgets('dismissing it hides it, and it stays hidden after a restart',
      (tester) async {
    final custody = MemoryBackupCustody();
    await openShell(tester, custody);
    await tester.tap(find.byKey(const Key('setup-reminder-dismiss')));
    await tester.pumpAndSettle();
    expect(reminder, findsNothing);
    expect(custody.dismissed, isTrue);

    await openShell(tester, custody);
    expect(reminder, findsNothing);
  });

  testWidgets('its door opens Backup, and a phrase kept there retires it',
      (tester) async {
    final custody = MemoryBackupCustody();
    await openShell(tester, custody);
    await tester.tap(find.byKey(const Key('setup-reminder-open')));
    await tester.pumpAndSettle();
    expect(find.text('Backup & migrate'), findsOneWidget);

    // Stands in for the mint + ask-back flow backup_screen_test covers.
    custody.phrase =
        'abandon abandon abandon abandon abandon abandon abandon abandon '
        'abandon abandon abandon about';
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(reminder, findsNothing);
  });

  testWidgets('never shown once a phrase is kept', (tester) async {
    await openShell(
        tester,
        MemoryBackupCustody(
            phrase: 'abandon abandon abandon abandon abandon abandon '
                'abandon abandon abandon abandon abandon about'));
    expect(reminder, findsNothing);
  });

  testWidgets('never shown on a surface with no keychain', (tester) async {
    await openShell(tester, null);
    expect(reminder, findsNothing);
  });

  testWidgets('fits a 320dp phone at 2x text with nothing overflowing',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await openShell(tester, MemoryBackupCustody());
    expect(reminder, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
