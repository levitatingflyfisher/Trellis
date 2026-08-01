import 'package:backup_core/backup_core.dart';
import 'package:flutter/material.dart';

import '../../db/database.dart';
import 'backup_gateway.dart';
import 'db_bridge.dart';

/// Backup & migrate: create/restore this app's encrypted `.ohbk`, or bring
/// a life over from either donor (Trellis `.ohbk`, ohPrimer JSON export).
///
/// The four flows share one passphrase field and one filesystem seam
/// ([BackupGateway]) and end in one of two calm surfaces: a snackbar for a
/// completed backup/restore, a [MigrationReport] dialog for a donor import
/// — three plain facts (came / counted out / stayed behind), no urgency.
///
/// Restore is FULL-REPLACE (see [DbBridge]); on success this screen pops
/// with `true` so the shell can walk back to the profile picker — the
/// profile it was holding may no longer exist.
class BackupScreen extends StatefulWidget {
  final AppDatabase db;
  final Profile profile;
  final BackupGateway gateway;
  BackupScreen(
      {super.key,
      required this.db,
      required this.profile,
      BackupGateway? gateway})
      : gateway = gateway ?? FilePickerBackupGateway();

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  final _phrase = TextEditingController();
  String? _status;
  bool _busy = false;

  DbBridge get _bridge => DbBridge(widget.db);

  @override
  void dispose() {
    _phrase.dispose();
    super.dispose();
  }

  /// Runs [flow] with the busy latch held and every failure mapped to a
  /// calm sentence — the crypto fails closed, so "it didn't open" is the
  /// whole truth the user needs.
  Future<void> _guard(Future<void> Function() flow) async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await flow();
    } on ArgumentError {
      // EspalierBackup's verdict on the phrase itself.
      setState(() => _status =
          "That doesn't look like a valid recovery phrase — check the 12 "
          'words and try again.');
    } on FormatException catch (e) {
      setState(() => _status = e.message);
    } catch (_) {
      // CryptoException and friends carry no user-serviceable detail: the
      // phrase is wrong, the file is for another app, or a byte changed.
      setState(() => _status =
          "That phrase doesn't open this file — wrong phrase, or a backup "
          'made by a different app.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createBackup() => _guard(() async {
        final payload = RowPayload.encode(await _bridge.exportTables(),
            createdAt: DateTime.now().toUtc());
        final blob =
            await EspalierBackup.encrypt(payload, phrase: _phrase.text.trim());
        final now = DateTime.now();
        final stamp = '${now.year}'
            '${now.month.toString().padLeft(2, '0')}'
            '${now.day.toString().padLeft(2, '0')}';
        if (await widget.gateway.saveBytes('espalier-$stamp.ohbk', blob)) {
          _snack('Backup saved.');
        }
      });

  Future<void> _restore() => _guard(() async {
        final blob = await widget.gateway.pickBytes();
        if (blob == null) return;
        final plain =
            await EspalierBackup.decrypt(blob, phrase: _phrase.text.trim());
        final decoded = RowPayload.decode(plain);
        if (!mounted) return;
        final when = decoded.createdAt?.toLocal();
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: const Text('Replace everything?'),
            content: Text(
                'Everything in this app is replaced by the backup'
                '${when == null ? '' : ' from ${when.year}-'
                    '${when.month.toString().padLeft(2, '0')}-'
                    '${when.day.toString().padLeft(2, '0')}'}. '
                'This cannot be undone.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialog, false),
                  child: const Text('Keep what I have')),
              FilledButton(
                  key: const Key('restore-confirm'),
                  onPressed: () => Navigator.pop(dialog, true),
                  child: const Text('Replace everything')),
            ],
          ),
        );
        if (confirmed != true) return;
        await _bridge.restoreFullReplace(decoded);
        _snack('Backup restored.');
        if (!mounted) return;
        // The profile this screen was opened with may be gone now.
        Navigator.of(context).maybePop(true);
      });

  Future<void> _importTrellis() => _guard(() async {
        final blob = await widget.gateway.pickBytes();
        if (blob == null) return;
        final result = await TrellisImporter.importBackup(blob,
            phrase: _phrase.text.trim(),
            profileId: '${widget.profile.id}');
        final report = await _bridge.applyTrellis(result,
            profileId: widget.profile.id,
            nowMs: DateTime.now().millisecondsSinceEpoch);
        await _showReport(report);
      });

  Future<void> _importPrimer() => _guard(() async {
        final text = await widget.gateway.pickText();
        if (text == null) return;
        final result = OhPrimerImporter.importJson(text,
            profileId: '${widget.profile.id}');
        final report = await _bridge.applyPrimer(result,
            profileId: widget.profile.id,
            nowMs: DateTime.now().millisecondsSinceEpoch);
        await _showReport(report);
      });

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// The table names a person would use, for the report's "came across"
  /// lines. Anything unmapped shows its raw name — honest over pretty.
  static const _tableWords = {
    'profiles': 'reader profiles',
    'works': 'works',
    'segments': 'passages',
    'positions': 'reading positions',
    'feeds': 'feeds',
    'courses': 'courses',
    'cards': 'cards',
    'revlog': 'review entries',
    'wordLedger': 'words for the ledger',
    'playerPositions': 'listening positions',
    'layers': 'translation layers',
    'alignments': 'alignments',
  };

  Future<void> _showReport(MigrationReport report) async {
    if (!mounted) return;
    final theme = Theme.of(context);
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        key: const Key('migration-report'),
        title: const Text('What came across'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (report.imported.isEmpty)
                const Text('Nothing new — it was all here already.'),
              for (final e in report.imported.entries)
                Text('• ${e.value} ${_tableWords[e.key] ?? e.key}'),
              if (report.skipped.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Counted, not imported',
                    style: theme.textTheme.labelLarge),
                for (final e in report.skipped.entries)
                  Text('• ${e.value} × ${e.key}',
                      style: theme.textTheme.bodySmall),
              ],
              if (report.dropped.isNotEmpty) ...[
                const SizedBox(height: 12),
                for (final sentence in report.dropped)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child:
                        Text(sentence, style: theme.textTheme.bodySmall),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Done')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Backup & migrate')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Your phrase', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            key: const Key('backup-phrase'),
            controller: _phrase,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'twelve words with spaces between',
              helperText: 'The household recovery phrase locks every backup. '
                  'Without it, a backup file opens for no one.',
              helperMaxLines: 3,
            ),
          ),
          if (_status != null) ...[
            const SizedBox(height: 8),
            Text(_status!,
                key: const Key('backup-status'),
                style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 24),
          Text('This app', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          FilledButton.icon(
              key: const Key('backup-save'),
              onPressed: _busy ? null : _createBackup,
              icon: const Icon(Icons.lock_outline),
              label: const Text('Save an encrypted backup')),
          const SizedBox(height: 12),
          OutlinedButton.icon(
              key: const Key('backup-restore'),
              onPressed: _busy ? null : _restore,
              icon: const Icon(Icons.settings_backup_restore),
              label: const Text('Restore a backup')),
          const SizedBox(height: 4),
          Text('Restoring replaces everything in this app.',
              style: theme.textTheme.bodySmall),
          const SizedBox(height: 24),
          Text('From the earlier apps', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          OutlinedButton.icon(
              key: const Key('import-trellis'),
              onPressed: _busy ? null : _importTrellis,
              icon: const Icon(Icons.school_outlined),
              label: const Text('Import a Trellis backup (.ohbk)')),
          const SizedBox(height: 12),
          OutlinedButton.icon(
              key: const Key('import-primer'),
              onPressed: _busy ? null : _importPrimer,
              icon: const Icon(Icons.menu_book_outlined),
              label: const Text('Import an ohPrimer export (.json)')),
          const SizedBox(height: 4),
          Text(
              'Imports add to this reader profile; nothing already here is '
              'touched. A small report shows what came across and what '
              'stayed behind.',
              style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
