// End-to-end net for Trellis's encrypted-backup wiring: the REAL
// TrellisBackupSerializer + real sanctuary_auth_core crypto (via
// DefaultCryptoService + InMemorySecureKeyStore, no OS keychain), driven
// through sanctuary_backup_ui's BackupController with Trellis's actual
// config (appId 'trellis', appDomain 'trellis', context
// 'trellis-backup/v1'). The generic controller behaviour (RestoreOutcome
// mapping, seed flows) is unit-tested in the package itself; this proves
// Trellis's own wiring — main.dart's provider overrides, reproduced here —
// actually works end to end (SANCTUARY-BRIEF §4.W2).

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary_auth_core/sanctuary_auth_core.dart';
import 'package:sanctuary_backup_ui/sanctuary_backup_ui.dart';
import 'package:sanctuary_backup_ui/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trellis/features/curriculum/data/course_repository.dart';
import 'package:trellis/features/sanctuary_backup/data/backup_serializer.dart';

const _validPhrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon about';

const _kalmanCourseJson =
    '{"schemaVersion":"1.0","id":"kalman-filters","title":"Kalman Filters"}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SharedPreferences> freshPrefs() async {
    SharedPreferences.setMockInitialValues({});
    return SharedPreferences.getInstance();
  }

  ProviderContainer makeContainer({
    required SharedPreferences prefs,
    required SecureKeyStore store,
    void Function(Ref ref)? onAfterRestore,
  }) {
    final c = ProviderContainer(overrides: [
      secureKeyStoreProvider.overrideWithValue(store),
      // v0.2.0's restore takes a MANDATORY verified pre-restore snapshot;
      // without an in-memory vault the platform store (path_provider) is
      // unavailable under test and every restore ends in snapshotFailed.
      vaultStoreProvider.overrideWithValue(InMemoryVaultStore()),
      cryptoServiceProvider.overrideWithValue(const DefaultCryptoService()),
      sanctuaryAppDomainProvider.overrideWithValue('trellis'),
      backupSerializerProvider
          .overrideWith((ref) => TrellisBackupSerializer(prefs)),
      sanctuaryBackupConfigProvider.overrideWithValue(
        SanctuaryBackupConfig(
          appId: 'trellis',
          aadContext: 'trellis-backup/v1',
          appDisplayName: 'Trellis',
          onAfterRestore: onAfterRestore,
        ),
      ),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test('export -> restore round-trips Trellis data through the controller',
      () async {
    final prefsA = await freshPrefs();
    await prefsA.setString(
        CourseRepository.courseKey('kalman-filters'), _kalmanCourseJson);
    await prefsA.setStringList(CourseRepository.indexKey, ['kalman-filters']);

    final src = makeContainer(
      prefs: prefsA,
      store: InMemorySecureKeyStore(
          mnemonic: _validPhrase, acknowledged: true),
    );
    final result =
        await src.read(backupControllerProvider.notifier).exportBackup();
    expect(result, isNotNull);
    expect(result!.filename,
        matches(RegExp(r'^trellis-backup-\d{4}-\d{2}-\d{2}\.ohbk$')));
    expect(result.bytes.sublist(0, 4), equals([0x4F, 0x48, 0x42, 0x4B]));

    // Restore into a fresh store with a fresh (empty) keychain, by phrase.
    final prefsB = await freshPrefs();
    var refreshed = false;
    final dst = makeContainer(
      prefs: prefsB,
      store: InMemorySecureKeyStore(),
      onAfterRestore: (_) => refreshed = true,
    );
    final outcome = await dst
        .read(backupControllerProvider.notifier)
        .restoreWithPhrase(result.bytes, _validPhrase);

    expect(outcome, RestoreOutcome.success);
    expect(refreshed, isTrue, reason: 'onAfterRestore must fire');
    expect(
      prefsB.getStringList(CourseRepository.indexKey),
      ['kalman-filters'],
    );
    expect(
      prefsB.getString(CourseRepository.courseKey('kalman-filters')),
      _kalmanCourseJson,
    );
  });

  test('a non-OHBK blob restores as corruptFile', () async {
    final prefs = await freshPrefs();
    final c = makeContainer(prefs: prefs, store: InMemorySecureKeyStore());
    final outcome = await c
        .read(backupControllerProvider.notifier)
        .restoreWithPhrase(Uint8List.fromList(List.filled(64, 0)), _validPhrase);
    expect(outcome, RestoreOutcome.corruptFile);
  });
}
