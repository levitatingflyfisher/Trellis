/// Campaign 4 Phase 4: the "Catch me up?" recap — reuses distill's own
/// consent order (`_distill`/`openDistillFlow`: gesture -> cloud-tier
/// consent -> Brain call) but shows its result in a bottom sheet rather
/// than a full-page push, since a recap is read once and dismissed, not a
/// saved artifact. Never persisted: the summary lives only in this
/// widget's state and is gone the moment the sheet closes.
library;

import 'dart:async';

import 'package:brain_wiring/brain_wiring.dart';
import 'package:flutter/material.dart';

// `Alignment` here is drift's generated row class for the Alignments
// table, colliding with Flutter's own painting Alignment used below —
// same collision reader_screen.dart already documents and hides.
import '../../db/database.dart' hide Alignment;
import '../brain/brain_labels.dart';
import '../brain/brain_store.dart';
import '../models/consent.dart';
import 'reader_logic.dart' show preCursorText;

/// The offer chip's tap handler. Same order [openDistillFlow] already
/// established: the tap is the human hand (ADR-0003 law 4); a cloud tier
/// names exactly what would leave the device and gets a real no/yes
/// BEFORE any byte moves; only then does the sheet ask the Brain.
Future<void> openRecapFlow(
  BuildContext context, {
  required AppDatabase db,
  required Work work,
  required int currentSegmentIdx,
  required BrainStore store,
}) async {
  const gesture = UserGesture();
  final use = await store.brainForUse();
  if (!context.mounted) return;
  switch (use) {
    case BrainNotConfigured(:final message):
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    case BrainReady():
      if (use.requiresEgressConsent) {
        final ok = await confirmDownload(context, items: [
          DownloadItem(
              'Send the text of “${work.title}” read so far to '
              '${use.egressHost} for a recap'),
        ]);
        if (!ok || !context.mounted) return;
      }
      final rows = await db.spineDao.segmentsOf(work.id);
      final textSoFar = preCursorText(
          [for (final r in rows) (idx: r.idx, body: r.body)],
          currentSegmentIdx);
      if (!context.mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => _RecapSheet(
            title: work.title,
            textSoFar: textSoFar,
            ready: use,
            gesture: gesture),
      );
  }
}

class _RecapSheet extends StatefulWidget {
  const _RecapSheet({
    required this.title,
    required this.textSoFar,
    required this.ready,
    required this.gesture,
  });

  final String title;
  final String textSoFar;
  final BrainReady ready;
  final UserGesture gesture;

  @override
  State<_RecapSheet> createState() => _RecapSheetState();
}

class _RecapSheetState extends State<_RecapSheet> {
  Recap? _result;
  String? _error;
  bool _running = true;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final result = await RecapGenerator(
              brain: widget.ready.brain, provenance: widget.ready.provenance)
          .recap(
              title: widget.title,
              textSoFar: widget.textSoFar,
              userGesture: widget.gesture);
      if (mounted) setState(() => _result = result);
    } on RecapFailedException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on AskException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = _result;
    final error = _error;
    return SafeArea(
      key: const Key('recap-sheet'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Catch me up?',
                      style: theme.textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                ),
                IconButton(
                  key: const Key('recap-sheet-close'),
                  icon: const Icon(Icons.close),
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_running)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (error != null)
              Text(error, style: theme.textTheme.bodyMedium)
            else if (result != null) ...[
              Text(result.summary, style: theme.textTheme.bodyLarge),
              const SizedBox(height: 8),
              Text(recapByLine(result.provenance),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                key: const Key('recap-sheet-regenerate'),
                onPressed: _running ? null : () => unawaited(_run()),
                icon: const Icon(Icons.refresh),
                label: const Text('Regenerate'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
