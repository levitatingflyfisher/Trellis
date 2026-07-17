// Proves TrellisApp wires sanctuary_backup_ui's silent app-open freshness
// net (BACKUP_RETENTION_SPEC §3): after the first frame the app calls
// runStartupMaintenance, which vaults a fresh snapshot when a key exists
// and the newest snapshot is stale (or, as here, there is none at all).
//
// The whole point of testing through TrellisApp — not the controller — is
// that the post-frame hook itself is the behavior under test: forgetting
// to call it is exactly the bug this net exists to catch.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary_auth_core/sanctuary_auth_core.dart';
import 'package:sanctuary_backup_ui/sanctuary_backup_ui.dart';
import 'package:sanctuary_backup_ui/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trellis/core/providers.dart';
import 'package:trellis/features/sanctuary_backup/data/backup_serializer.dart';
import 'package:trellis/main.dart';

const _mnemonic = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<List<Override>> overridesWith({
    required SecureKeyStore store,
    required InMemoryVaultStore vault,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    return [
      sharedPreferencesProvider.overrideWithValue(prefs),
      // Deterministic empty library: keep the test off rootBundle I/O,
      // which testWidgets' fake async can't drive.
      coursesProvider.overrideWith((ref) async => const []),
      secureKeyStoreProvider.overrideWithValue(store),
      cryptoServiceProvider.overrideWithValue(FakeCryptoService()),
      vaultStoreProvider.overrideWithValue(vault),
      sanctuaryAppDomainProvider.overrideWithValue('trellis'),
      sanctuaryBackupConfigProvider.overrideWithValue(
        const SanctuaryBackupConfig(
          appId: 'trellis',
          aadContext: 'trellis-backup/v1',
          appDisplayName: 'Trellis',
        ),
      ),
      backupSerializerProvider
          .overrideWith((ref) => TrellisBackupSerializer(prefs)),
    ];
  }

  testWidgets(
      'app boot takes a freshness snapshot when a key exists and the vault '
      'is stale/empty', (tester) async {
    final vault = InMemoryVaultStore();
    final overrides = await overridesWith(
      store: InMemorySecureKeyStore(mnemonic: _mnemonic, acknowledged: true),
      vault: vault,
    );

    await tester.pumpWidget(
      ProviderScope(overrides: overrides, child: const TrellisApp()),
    );
    await tester.pumpAndSettle();

    final entries = await vault.list();
    expect(entries, hasLength(1),
        reason: 'the post-frame hook must vault one freshness snapshot');
    expect(entries.single.label, VaultLabel.freshness);
  });

  testWidgets('app boot with no key set up never touches the vault',
      (tester) async {
    final vault = InMemoryVaultStore();
    final overrides = await overridesWith(
      store: InMemorySecureKeyStore(), // fresh install: no mnemonic
      vault: vault,
    );

    await tester.pumpWidget(
      ProviderScope(overrides: overrides, child: const TrellisApp()),
    );
    await tester.pumpAndSettle();

    expect(await vault.list(), isEmpty);
  });
}
