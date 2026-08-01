/// Campaign 4 Phase 3: the tap-hold definition sheet — a calm,
/// dismissible bottom sheet showing an on-device dictionary lookup for a
/// held word. This is now the ONE place a long-pressed word's "keep to
/// the word ledger" action lives: it absorbs that gesture (the handoff's
/// own discovery #4) rather than stacking a second long-press on top of
/// the reader's existing one.
library;

import 'package:flutter/material.dart';

/// Opens the sheet for [word]. [lookupDefinition] is the caller's
/// DeviceServices.lookupDefinition, closed over so this widget never
/// reaches a device-services mock in its own tests. [onKeep] is the
/// existing ledger add (ReaderScreen._keepWord), unchanged — the sheet
/// only decides WHEN it runs, not what it does.
Future<void> showDefinitionSheet(
  BuildContext context, {
  required String word,
  required Future<String?> Function(String word) lookupDefinition,
  required Future<void> Function() onKeep,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _DefinitionSheet(
        word: word, lookupDefinition: lookupDefinition, onKeep: onKeep),
  );
}

class _DefinitionSheet extends StatefulWidget {
  const _DefinitionSheet(
      {required this.word,
      required this.lookupDefinition,
      required this.onKeep});

  final String word;
  final Future<String?> Function(String word) lookupDefinition;
  final Future<void> Function() onKeep;

  @override
  State<_DefinitionSheet> createState() => _DefinitionSheetState();
}

class _DefinitionSheetState extends State<_DefinitionSheet> {
  String? _definition;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    widget.lookupDefinition(widget.word).then((def) {
      if (!mounted) return;
      setState(() {
        _definition = def;
        _loaded = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      key: const Key('dictionary-sheet'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(widget.word,
                      style: theme.textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                ),
                IconButton(
                  key: const Key('definition-sheet-close'),
                  icon: const Icon(Icons.close),
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (!_loaded)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_definition == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No definition available on this device. Download a '
                  'dictionary from Models to look words up offline.',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              )
            else
              Text(_definition!, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                key: const Key('definition-sheet-keep'),
                onPressed: () async {
                  await widget.onKeep();
                  // One tap, done — closing here keeps this at least as
                  // fast as the plain long-press-to-keep gesture it
                  // replaces, and lets onKeep's own snackbar show clearly
                  // once the sheet is out of the way.
                  if (context.mounted) Navigator.of(context).pop();
                },
                icon: const Icon(Icons.bookmark_add_outlined),
                label: const Text('Add to word ledger'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
