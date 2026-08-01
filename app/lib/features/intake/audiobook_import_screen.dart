/// The audiobook door's dialog (ADR-0013, Campaign 7) — pick files, confirm
/// (or edit) a guessed title, copy. Mirrors `paste_intake.dart`'s
/// `_PasteDialog` shape; the only new wrinkle is a "Copying…" state, since
/// unlike pasted text this door's confirm step touches real files.
library;

import 'package:flutter/material.dart';
import 'package:intake_core/intake_core.dart';

import 'audiobook_import.dart';
import 'audiobook_picker_gateway.dart';

/// Picks files, confirms a title, imports. Returns the new work id, or
/// null if the picker was dismissed with nothing chosen, or the confirm
/// dialog was cancelled.
Future<int?> pickAndImportAudiobook(
  BuildContext context, {
  required int profileId,
  required AudiobookPickerGateway gateway,
  required AudiobookImportRepository repository,
}) async {
  final picked = await gateway.pickFiles();
  if (picked == null || picked.isEmpty) return null;
  final orderedNames = orderAudiobookFiles([for (final f in picked) f.name]);
  final defaultTitle = defaultAudiobookTitle(orderedNames);
  if (!context.mounted) return null;
  return showDialog<int>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _AudiobookImportDialog(
      profileId: profileId,
      picked: picked,
      defaultTitle: defaultTitle,
      repository: repository,
    ),
  );
}

class _AudiobookImportDialog extends StatefulWidget {
  final int profileId;
  final List<PickedAudioFile> picked;
  final String defaultTitle;
  final AudiobookImportRepository repository;
  const _AudiobookImportDialog({
    required this.profileId,
    required this.picked,
    required this.defaultTitle,
    required this.repository,
  });

  @override
  State<_AudiobookImportDialog> createState() =>
      _AudiobookImportDialogState();
}

class _AudiobookImportDialogState extends State<_AudiobookImportDialog> {
  late final _title = TextEditingController(text: widget.defaultTitle);
  bool _importing = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    setState(() {
      _importing = true;
      _error = null;
    });
    final title = _title.text.trim().isEmpty
        ? widget.defaultTitle
        : _title.text.trim();
    final outcome = await widget.repository.import(
      profileId: widget.profileId,
      picked: widget.picked,
      title: title,
    );
    if (!mounted) return;
    if (outcome == null) {
      setState(() {
        _importing = false;
        _error = "None of those files could be read — nothing was imported.";
      });
      return;
    }
    Navigator.pop(context, outcome.workId);
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.picked.length;
    return AlertDialog(
      title: const Text('Audiobook'),
      content: _importing
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 16),
                Text('Copying $n file${n == 1 ? '' : 's'}…'),
              ],
            )
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const Key('audiobook-title'),
                    controller: _title,
                    decoration: const InputDecoration(labelText: 'Title'),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '$n file${n == 1 ? '' : 's'}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
      actions: _importing
          ? const []
          : [
              TextButton(
                onPressed: () => Navigator.pop(context, null),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('audiobook-import-confirm'),
                onPressed: _confirm,
                child: const Text('Import'),
              ),
            ],
    );
  }
}
