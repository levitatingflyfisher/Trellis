import 'dart:typed_data';

import 'package:backup_core/backup_core.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:sanctuary_auth_core/sanctuary_auth_core.dart'
    show CryptoException;
import 'package:sanctuary_backup_ui/sanctuary_backup_ui.dart'
    show PhraseEntryDialog, PhraseReEntryDialog, SeedPhraseModal;

import '../../db/database.dart';
import 'backup_custody.dart';
import 'backup_gateway.dart';
import 'db_bridge.dart';
import '../shared/capped_body.dart';
import '../shared/error_line.dart';

/// Seals a backup payload under a phrase — [EspalierBackup.encrypt] in
/// production; a seam so a test can hand back a damaged blob.
typedef BackupSealer = Future<Uint8List> Function(Uint8List payload,
    {required String phrase});

/// Backup & migrate: create/restore this app's encrypted `.ohbk`, or bring
/// a life over from either donor (Trellis `.ohbk`, ohPrimer JSON export).
///
/// The four flows share one passphrase field and one filesystem seam
/// ([BackupGateway]) and end in one of two calm surfaces: a snackbar for a
/// completed backup/restore, a [MigrationReport] dialog for a donor import
/// — three plain facts (came / counted out / stayed behind), no urgency.
///
/// Someone without a phrase mints it here ([EspalierBackup.newPhrase], the
/// fleet's generator): the words are shown, then asked back. A phrase typed
/// from memory is asked back once before the first write — a mistyped word
/// that happens to be valid BIP39 would otherwise lock a file that opens
/// for no one. Once confirmed, the phrase is kept on the device
/// ([BackupCustody], the fleet's key model), so later backups ask for
/// nothing; a restore or import whose file was made under other words asks
/// for those words.
///
/// Restore is FULL-REPLACE (see [DbBridge]); on success this screen pops
/// with `true` so the shell can walk back to the profile picker — the
/// profile it was holding may no longer exist.
class BackupScreen extends StatefulWidget {
  final AppDatabase db;
  final Profile profile;
  final BackupGateway gateway;

  /// Mints a fresh recovery phrase; a seam so tests can type a known one.
  final String Function() newPhrase;

  /// How a backup is sealed before it is re-opened in memory and saved.
  final BackupSealer seal;

  /// Where the confirmed phrase is kept. Null on a surface with no keychain
  /// (plain widget tests): the phrase is then typed every time.
  final BackupCustody? custody;
  BackupScreen(
      {super.key,
      required this.db,
      required this.profile,
      BackupGateway? gateway,
      String Function()? newPhrase,
      BackupSealer? seal,
      this.custody})
      : gateway = gateway ?? FilePickerBackupGateway(),
        newPhrase = newPhrase ?? EspalierBackup.newPhrase,
        seal = seal ?? EspalierBackup.encrypt;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  final _phrase = TextEditingController();
  String? _status;
  bool _busy = false;

  /// The phrase the user has proven they hold this session (shown and asked
  /// back, or typed twice). Saving under it needs no second ask.
  String? _provenPhrase;

  /// The confirmed phrase kept on this device, once loaded.
  String? _kept;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadKept();
  }

  Future<void> _loadKept() async {
    final kept = await widget.custody?.readPhrase();
    if (!mounted) return;
    setState(() {
      _kept = kept;
      _loaded = true;
    });
  }

  /// Keeps a phrase the user has just proven they hold.
  Future<void> _keep(String phrase) async {
    _provenPhrase = phrase;
    final custody = widget.custody;
    if (custody == null) return;
    try {
      await custody.savePhrase(phrase);
    } catch (_) {
      // A different phrase is already on the device (or the keychain can't
      // be checked): it is never overwritten. This phrase still works for
      // this session; it just isn't kept.
      return;
    }
    if (!mounted) return;
    setState(() => _kept = phrase);
  }

  /// Runs [open] under the kept phrase (or the typed one when nothing is
  /// kept). A file made under other words — another device, an older
  /// phrase — asks for those words once instead of failing outright.
  /// Returns null when the user backs out.
  Future<T?> _withPhrase<T>(Future<T> Function(String phrase) open) async {
    final kept = _kept;
    if (kept == null) return open(_phrase.text.trim());
    try {
      return await open(kept);
    } on CryptoException {
      if (!mounted) return null;
      final typed = await PhraseEntryDialog.show(
        context,
        title: "Enter the backup’s recovery words",
        body: 'This file was made with different words than the ones kept '
            'on this device. Enter the 12 words it was made with.',
        confirmLabel: 'Open',
      );
      if (typed == null) return null;
      return open(typed.trim());
    }
  }

  static String _normalized(String phrase) =>
      phrase.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');

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
          "That doesn’t look like a valid recovery phrase. Check the 12 "
          'words and try again.');
    } on FormatException catch (e) {
      // backup_core's words ("Missing schemaVersion…") are for the log.
      debugPrint('Backup file refused: ${e.message}');
      setState(() => _status =
          "That file isn’t a Trellis backup this version can open. It may "
          'be from another app, or damaged.');
    } catch (_) {
      // CryptoException and friends carry no user-serviceable detail: the
      // phrase is wrong, the file is for another app, or a byte changed.
      setState(() => _status =
          "That phrase doesn’t open this file: wrong phrase, or a backup "
          'made by a different app.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Mints a phrase, shows it (must be acknowledged, not swiped away), then
  /// checks the paper copy word by word (sanctuary's PhraseReEntryDialog:
  /// "Word 5 of 12", a slip named in place, earlier words kept). Only a
  /// fully matched phrase fills the field; backing out leaves it empty.
  Future<void> _mintPhrase() async {
    // A phrase already on the device but never acknowledged is offered
    // back instead of a fresh one — backups made under it exist.
    final phrase =
        await widget.custody?.readUnconfirmedPhrase() ?? widget.newPhrase();
    if (!mounted) return;
    Future<void> showWords() => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          isDismissible: false,
          enableDrag: false,
          builder: (_) =>
              SeedPhraseModal(phrase: phrase, onAcknowledged: () {}),
        );
    await showWords();
    if (!mounted) return;
    final typed = await PhraseReEntryDialog.show(context,
        expectedPhrase: phrase, onShowWords: showWords);
    if (typed == null || !mounted) return;
    if (_normalized(typed) != _normalized(phrase)) return;
    setState(() {
      _phrase.text = phrase;
      _status = null;
    });
    await _keep(phrase);
  }

  /// A typed phrase not yet proven this session is asked back once.
  /// Returns false (and says so) when the copy doesn't match.
  Future<bool> _askBack(String phrase) async {
    if (_provenPhrase != null &&
        _normalized(_provenPhrase!) == _normalized(phrase)) {
      return true;
    }
    final typed = await PhraseEntryDialog.show(
      context,
      title: 'Type your phrase again',
      body: 'Once more, from your paper copy. A backup locked with a '
          'mistyped word opens for no one.',
      confirmLabel: 'Confirm',
    );
    if (typed == null || !mounted) return false;
    if (_normalized(typed) != _normalized(phrase)) {
      setState(() => _status =
          "The two phrases didn’t match, so nothing was saved. Check your "
          'paper copy and try again.');
      return false;
    }
    await _keep(phrase);
    return true;
  }

  Future<void> _createBackup() async {
    final kept = _kept;
    if (kept != null) return _writeBackup(kept);
    final phrase = _phrase.text.trim();
    if (!EspalierBackup.isValidPhrase(phrase)) {
      // The same calm verdict the encrypt path gives, before any dialog.
      return _guard(() async => throw ArgumentError('invalid phrase'));
    }
    if (!await _askBack(phrase)) return;
    await _writeBackup(phrase);
  }

  Future<void> _writeBackup(String phrase) => _guard(() async {
        final payload = RowPayload.encode(await _bridge.exportTables(),
            createdAt: DateTime.now().toUtc());
        final blob = await widget.seal(payload, phrase: phrase);
        // Untested backups don't count: re-open the exact bytes about to be
        // saved, in memory, and only save (and say so) if they come back
        // whole.
        var opens = false;
        try {
          opens = listEquals(
              await EspalierBackup.decrypt(blob, phrase: phrase), payload);
        } catch (_) {
          opens = false;
        }
        if (!opens) {
          if (mounted) {
            setState(() => _status =
                "The backup didn’t open again when checked, so it was not "
                'saved. Please try again.');
          }
          return;
        }
        final now = DateTime.now();
        final stamp = '${now.year}'
            '${now.month.toString().padLeft(2, '0')}'
            '${now.day.toString().padLeft(2, '0')}';
        if (await widget.gateway.saveBytes('trellis-backup-$stamp.ohbk', blob)) {
          await widget.custody?.recordBackup(DateTime.now());
          _snack('Backup saved and checked.');
        }
      });

  Future<void> _restore() => _guard(() async {
        final blob = await widget.gateway.pickBytes();
        if (blob == null) return;
        final plain = await _withPhrase(
            (phrase) => EspalierBackup.decrypt(blob, phrase: phrase));
        if (plain == null) return;
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
            // The safe answer carries the emphasis (audit mind-04); the
            // destructive one is marked by the urgency icon and colour, not
            // by weight, so a reflexive tap on the bold button keeps data.
            actions: [
              TextButton.icon(
                  key: const Key('restore-confirm'),
                  style: TextButton.styleFrom(
                      foregroundColor: Theme.of(dialog).colorScheme.error),
                  onPressed: () => Navigator.pop(dialog, true),
                  icon: const Icon(Icons.report_outlined),
                  label: const Text('Replace everything')),
              FilledButton(
                  onPressed: () => Navigator.pop(dialog, false),
                  child: const Text('Keep what I have')),
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
        final result = await _withPhrase((phrase) =>
            TrellisImporter.importBackup(blob,
                phrase: phrase, profileId: '${widget.profile.id}'));
        if (result == null) return;
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
                const Text('Nothing new. It was all here already.'),
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
      body: CappedBody(child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Your phrase', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_kept != null)
            Text(
                "This app’s recovery phrase is kept safely on this device, "
                "so backups don’t ask for it. Keep your paper copy: a new "
                'device will.',
                key: const Key('backup-phrase-kept'),
                style: theme.textTheme.bodyMedium)
          else if (widget.custody == null || _loaded) ...[
            TextField(
              key: const Key('backup-phrase'),
              controller: _phrase,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'twelve words with spaces between',
                helperText: "This app’s recovery phrase locks every backup. "
                    'Without it, a backup file opens for no one.',
                helperMaxLines: 3,
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                  key: const Key('backup-new-phrase'),
                  onPressed: _busy ? null : _mintPhrase,
                  icon: const Icon(Icons.key_outlined),
                  label: const Text("No phrase yet? Make one")),
            ),
          ],
          if (_status != null) ...[
            const SizedBox(height: 8),
            ErrorLine(_status!, textKey: const Key('backup-status')),
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
      )),
    );
  }
}
