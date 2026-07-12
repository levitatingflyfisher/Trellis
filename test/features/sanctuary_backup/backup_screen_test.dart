// Widget tests for BackupScreen — the minimal host for
// sanctuary_backup_ui's BackupSettingsSection (SANCTUARY-BRIEF §4.W2
// app-specific block: Trellis has no settings screen, so backup gets its
// own small screen off LibraryScreen's AppBar).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary_auth_core/sanctuary_auth_core.dart';
import 'package:sanctuary_backup_ui/sanctuary_backup_ui.dart';
import 'package:sanctuary_backup_ui/testing.dart';
import 'package:trellis/features/sanctuary_backup/presentation/backup_screen.dart';

const _ackedMnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

Widget _wrapWithProviders(SecureKeyStore store) {
  return ProviderScope(
    overrides: [
      secureKeyStoreProvider.overrideWithValue(store),
      cryptoServiceProvider.overrideWithValue(FakeCryptoService()),
      sanctuaryAppDomainProvider.overrideWithValue('trellis'),
      sanctuaryBackupConfigProvider.overrideWithValue(
        const SanctuaryBackupConfig(
          appId: 'trellis',
          aadContext: 'trellis-backup/v1',
          appDisplayName: 'Trellis',
        ),
      ),
      backupSerializerProvider.overrideWithValue(FakeBackupSerializer()),
    ],
    child: const MaterialApp(home: BackupScreen()),
  );
}

void main() {
  group('BackupScreen', () {
    testWidgets('hosts the encrypted-backup section', (tester) async {
      await tester.pumpWidget(_wrapWithProviders(InMemorySecureKeyStore()));
      await tester.pumpAndSettle();

      expect(find.text('Backup & Restore'), findsOneWidget);
      expect(find.text('Encrypted Backup'), findsOneWidget);
      expect(find.text('Set up encrypted backup'), findsOneWidget);
      expect(find.text('Restore from backup'), findsOneWidget);
    });

    testWidgets('shows Export once the seed is acknowledged', (tester) async {
      await tester.pumpWidget(_wrapWithProviders(InMemorySecureKeyStore(
          mnemonic: _ackedMnemonic, acknowledged: true)));
      await tester.pumpAndSettle(const Duration(seconds: 5));

      expect(find.text('Export backup'), findsOneWidget);
    });

    testWidgets('no overflow at 320dp x textScale 3.0 (no key yet)',
        (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(320, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            secureKeyStoreProvider
                .overrideWithValue(InMemorySecureKeyStore()),
            cryptoServiceProvider.overrideWithValue(FakeCryptoService()),
            sanctuaryAppDomainProvider.overrideWithValue('trellis'),
            sanctuaryBackupConfigProvider.overrideWithValue(
              const SanctuaryBackupConfig(
                appId: 'trellis',
                aadContext: 'trellis-backup/v1',
                appDisplayName: 'Trellis',
              ),
            ),
            backupSerializerProvider.overrideWithValue(FakeBackupSerializer()),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(3.0)),
              child: child!,
            ),
            home: const BackupScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull,
          reason: 'no RenderFlex overflow at narrow width + large text scale');
    });

    testWidgets(
        'no overflow at 320dp x textScale 3.0 (key set up + acknowledged)',
        (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(320, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            secureKeyStoreProvider.overrideWithValue(InMemorySecureKeyStore(
                mnemonic: _ackedMnemonic, acknowledged: true)),
            cryptoServiceProvider.overrideWithValue(FakeCryptoService()),
            sanctuaryAppDomainProvider.overrideWithValue('trellis'),
            sanctuaryBackupConfigProvider.overrideWithValue(
              const SanctuaryBackupConfig(
                appId: 'trellis',
                aadContext: 'trellis-backup/v1',
                appDisplayName: 'Trellis',
              ),
            ),
            backupSerializerProvider.overrideWithValue(FakeBackupSerializer()),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(3.0)),
              child: child!,
            ),
            home: const BackupScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 5));

      expect(tester.takeException(), isNull,
          reason: 'no RenderFlex overflow at narrow width + large text scale');
    });
  });
}
