import 'package:flutter/material.dart';
import 'package:sanctuary_backup_ui/sanctuary_backup_ui.dart';

/// Trellis has no settings screen (SANCTUARY-BRIEF §4.W2 app-specific
/// block) — this is a minimal, dedicated host for the drop-in encrypted-
/// backup section, reached from LibraryScreen's AppBar. Kept calm and
/// small: a title and the section, nothing else.
class BackupScreen extends StatelessWidget {
  const BackupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Backup & Restore')),
      body: ListView(
        children: const [BackupSettingsSection()],
      ),
    );
  }
}
