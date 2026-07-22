import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sanctuary_auth_core/sanctuary_auth_core.dart';
import 'package:sanctuary_backup_ui/sanctuary_backup_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/providers.dart';
import 'core/theme.dart';
import 'features/curriculum/presentation/library_screen.dart';
import 'features/sanctuary_backup/data/backup_serializer.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        // Encrypted-backup wiring (sanctuary_backup_ui). Trellis is a NEW
        // sanctuary app, so it gets its own isolated key material via
        // appDomain (SANCTUARY-BRIEF §2.1) rather than the legacy
        // household-wide derivation Lullaby keeps for compatibility.
        sanctuaryAppDomainProvider.overrideWithValue('trellis'),
        sanctuaryBackupConfigProvider.overrideWithValue(
          SanctuaryBackupConfig(
            appId: 'trellis',
            aadContext: 'trellis-backup/v1',
            appDisplayName: 'Trellis',
            restoreReplaceConsequence:
                'Restoring will delete all imported courses and study '
                'progress on this device, then replace them with the '
                'contents of the backup file. Bundled courses are '
                'unaffected — they ship with the app.',
            // coursesProvider caches the merged bundled+imported course
            // list; a restore rewrites which imported courses exist (and
            // CourseRepository's own bundled-asset cache is untouched), so
            // it's the one provider a destructive restore can leave stale.
            // Per-course SM-2 progress is imperative local State reloaded
            // whenever a course/study screen is (re-)entered, not held in a
            // provider — nothing else to invalidate.
            onAfterRestore: (ref) => ref.invalidate(coursesProvider),
          ),
        ),
        backupSerializerProvider.overrideWith(
          (ref) =>
              TrellisBackupSerializer(ref.watch(sharedPreferencesProvider)),
        ),
      ],
      child: const TrellisApp(),
    ),
  );
}

class TrellisApp extends ConsumerStatefulWidget {
  const TrellisApp({super.key});

  @override
  ConsumerState<TrellisApp> createState() => _TrellisAppState();
}

class _TrellisAppState extends ConsumerState<TrellisApp> {
  @override
  void initState() {
    super.initState();
    // Silent freshness snapshot (BACKUP_RETENTION_SPEC §3): if the newest
    // vault snapshot is >7 days old and a key exists, take one. Post-frame
    // + fire-and-forget — never blocks boot, never surfaces errors. (The
    // Sundial pattern; extra valuable here because Trellis's restore is
    // SharedPreferences-based and not crash-atomic, so the vault is the
    // safety net.)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(backupControllerProvider.notifier).runStartupMaintenance();
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Trellis',
      debugShowCheckedModeBanner: false,
      theme: trellisTheme(Brightness.light),
      darkTheme: trellisTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const LibraryScreen(),
    );
  }
}
