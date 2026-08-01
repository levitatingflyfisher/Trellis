/// "Distill into a course" (proposal-2 §7): the open work's text through
/// whichever Brain the user pinned, gated by the package Distiller's
/// must-parse invariant, saved through the SAME strict-parser path
/// course_import uses — never a half-imported course.
///
/// Order of the flow, which is the law (ADR-0003 laws 4 + 6):
///  1. the menu tap is the [UserGesture] — nothing here runs unprompted;
///  2. a cloud tier passes THE consent chokepoint ([confirmDownload])
///     naming exactly what would leave the device, before any byte moves;
///  3. only then does the Distiller ask the Brain, with its ≤3 repair
///     rounds; the budget running out is a visible, honest failure.
library;

import 'package:brain_wiring/brain_wiring.dart';
import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../models/consent.dart';
import '../study/course_import.dart';
import 'brain_labels.dart';
import 'brain_store.dart';

/// The overflow-menu entry point. Shows the calm one-line explanation when
/// no Brain is configured; otherwise walks consent (cloud tiers only) and
/// pushes the progress screen.
Future<void> openDistillFlow(
  BuildContext context, {
  required AppDatabase db,
  required int profileId,
  required Work work,
  required BrainStore store,
}) async {
  // The tap that chose the menu item is the human hand (ADR-0003 law 4).
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
              'Send the text of “${work.title}” to ${use.egressHost} to '
              'distill a course — the reply size is unknown until it '
              'arrives'),
        ]);
        if (!ok || !context.mounted) return;
      }
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => DistillScreen(
            db: db,
            profileId: profileId,
            work: work,
            ready: use,
            gesture: gesture),
      ));
  }
}

/// Counts the Distiller's Brain calls so the progress line can say which
/// round is running — the wrapper adds nothing else.
class _AttemptCountingBrain implements Brain {
  _AttemptCountingBrain(this._inner, this._onAttempt);

  final Brain _inner;
  final void Function(int attempt) _onAttempt;
  int _attempts = 0;

  @override
  Future<String> complete(String prompt) {
    _onAttempt(++_attempts);
    return _inner.complete(prompt);
  }
}

class DistillScreen extends StatefulWidget {
  const DistillScreen({
    super.key,
    required this.db,
    required this.profileId,
    required this.work,
    required this.ready,
    required this.gesture,
  });

  final AppDatabase db;
  final int profileId;
  final Work work;
  final BrainReady ready;
  final UserGesture gesture;

  @override
  State<DistillScreen> createState() => _DistillScreenState();
}

class _DistillScreenState extends State<DistillScreen> {
  int _attempt = 0;
  DistilledCourse? _result;
  String? _error;
  String? _errorDetail;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final rows = await widget.db.spineDao.segmentsOf(widget.work.id);
    final source = [
      for (final r in rows)
        if (r.body.trim().isNotEmpty) r.body
    ].join('\n\n');
    if (source.isEmpty) {
      if (mounted) {
        setState(
            () => _error = 'Nothing to distill — this work has no text yet.');
      }
      return;
    }

    final distiller = Distiller(
      brain: _AttemptCountingBrain(widget.ready.brain, (n) {
        if (mounted) setState(() => _attempt = n);
      }),
      provenance: widget.ready.provenance,
    );
    try {
      final distilled = await distiller.distill(
          source: source, userGesture: widget.gesture);
      // The same save path course_import uses: the strict parser has the
      // last word before a row may exist.
      await importCourseText(
          db: widget.db,
          profileId: widget.profileId,
          raw: distilled.ohcourseJson);
      if (mounted) setState(() => _result = distilled);
    } on DistillFailedException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _errorDetail = e.lastError.message;
        });
      }
    } on AskException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final error = _error;
    return Scaffold(
      appBar: AppBar(title: const Text('Distill')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: switch ((result, error)) {
                (final DistilledCourse r, _) => _done(context, r),
                (null, final String e) => _failed(context, e),
                _ => _running(context),
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _running(BuildContext context) {
    final theme = Theme.of(context);
    final status = _attempt <= 1
        ? 'Asking the model…'
        : 'Round $_attempt — repairing the course…';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(status,
            style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text('“${widget.work.title}” is being distilled into a course. '
            'This can take a minute.',
            style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
      ],
    );
  }

  Widget _done(BuildContext context, DistilledCourse r) {
    final theme = Theme.of(context);
    final n = r.course.nodes.length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.eco_outlined,
            size: 56, color: theme.colorScheme.primary),
        const SizedBox(height: 12),
        Text('“${r.course.title}” is ready.',
            style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(
            '$n concept${n == 1 ? '' : 's'} · '
            '${r.repairRounds == 0 ? 'clean first pass' : '${r.repairRounds} repair round${r.repairRounds == 1 ? '' : 's'}'}',
            style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
        const SizedBox(height: 4),
        // Who thought — stamped in the file, named on the surface.
        Text(distilledByLine(r.provenance),
            key: const Key('distill-provenance'),
            style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        Text('Find it in the Courses tab.',
            style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
        const SizedBox(height: 24),
        FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done')),
      ],
    );
  }

  Widget _failed(BuildContext context, String message) {
    final theme = Theme.of(context);
    final detail = _errorDetail;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.cloud_off_outlined,
            size: 56, color: theme.colorScheme.secondary),
        const SizedBox(height: 12),
        Text(message,
            style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
        if (detail != null) ...[
          const SizedBox(height: 8),
          // The last path-qualified validator error, honestly shown.
          Text(detail,
              style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
        ],
        const SizedBox(height: 24),
        FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close')),
      ],
    );
  }
}
