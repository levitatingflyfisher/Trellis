/// The live job cards over the river: one per transcribing episode —
/// chunks done / total with the runner's honest ETA while running, a
/// resumable "Paused" card after a cancel or a kill, a calm retry after a
/// failure. The progress here (and its notification twin) is the only
/// notification-shaped thing this app ships (ADR-0003 law 5).
library;

import 'package:flutter/material.dart';

import '../models/format.dart';
import 'transcribe_coordinator.dart';

/// What transcribing will roughly cost, in words: `about N min` from the
/// episode's length and this phone's measured speed, or an honest
/// "time unknown" when either is missing.
String transcribeEstimate(int? durationMs, double? realtimeFraction) {
  if (durationMs == null || durationMs <= 0 || realtimeFraction == null) {
    return 'time unknown';
  }
  final minutes = (durationMs * realtimeFraction / 60000).ceil();
  // Words, not the approximately sign: no bundled font draws it (C7).
  return 'about ${minutes < 1 ? 1 : minutes} min';
}

class TranscribeJobCards extends StatelessWidget {
  final TranscribeCoordinator coordinator;

  /// Only this work's card, for a screen about one work.
  final int? workId;
  const TranscribeJobCards(
      {super.key, required this.coordinator, this.workId});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: coordinator,
      builder: (context, _) {
        final cards = [
          for (final c in coordinator.cards)
            if (workId == null || c.workId == workId) c
        ];
        if (cards.isEmpty) return const SizedBox.shrink();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [for (final c in cards) TranscribeJobCard(coordinator: coordinator, card: c)],
        );
      },
    );
  }
}

class TranscribeJobCard extends StatelessWidget {
  final TranscribeCoordinator coordinator;
  final TranscribeCardState card;
  const TranscribeJobCard(
      {super.key, required this.coordinator, required this.card});

  bool get _running =>
      card.phase != TranscribePhase.paused &&
      card.phase != TranscribePhase.failed;

  String get _status {
    final eta = formatEta(card.etaMs);
    switch (card.phase) {
      case TranscribePhase.fetchingModel:
        final total = card.totalBytes;
        final got = card.receivedBytes ?? 0;
        return 'Getting the model: ${formatBytes(got)}'
            '${total == null ? '' : ' of ${formatBytes(total)}'}'
            '${eta.isEmpty ? '' : ' · $eta'}';
      case TranscribePhase.fetchingAudio:
        final total = card.totalBytes;
        final got = card.receivedBytes;
        if (got == null) return 'Getting the episode audio…';
        return 'Getting the episode audio: ${formatBytes(got)}'
            '${total == null ? '' : ' of ${formatBytes(total)}'}';
      case TranscribePhase.waiting:
        final total = card.totalUnits;
        return total == null
            ? 'Picking up where it stopped…'
            : 'Picking up where it stopped: ${card.doneUnits ?? 0} of '
                '$total parts already done';
      case TranscribePhase.preparing:
        return 'Preparing audio…';
      case TranscribePhase.transcribing:
      case TranscribePhase.translating:
        final verb = card.phase == TranscribePhase.transcribing
            ? 'Transcribing'
            : 'Translating to English';
        final total = card.totalUnits;
        if (total == null) return '$verb…';
        return '$verb: ${card.doneUnits ?? 0} of $total parts'
            '${eta.isEmpty ? '' : ' · $eta'}';
      case TranscribePhase.paused:
        final total = card.totalUnits;
        return total == null
            ? 'Paused'
            : 'Paused: ${card.doneUnits ?? 0} of $total parts done';
      case TranscribePhase.failed:
        final why = card.error;
        return why == null
            ? 'Didn’t finish. Your progress is saved.'
            : 'Didn’t finish. $why';
    }
  }

  double? get _progressValue {
    switch (card.phase) {
      case TranscribePhase.fetchingModel:
      case TranscribePhase.fetchingAudio:
        final total = card.totalBytes;
        if (total == null || total == 0) return null;
        return (card.receivedBytes ?? 0) / total;
      case TranscribePhase.transcribing:
      case TranscribePhase.translating:
      case TranscribePhase.waiting:
      case TranscribePhase.paused:
        final total = card.totalUnits;
        if (total == null || total == 0) {
          return card.phase == TranscribePhase.transcribing ||
                  card.phase == TranscribePhase.translating
              ? null
              : 0;
        }
        return (card.doneUnits ?? 0) / total;
      case TranscribePhase.preparing:
        return null;
      case TranscribePhase.failed:
        return 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final workId = card.workId;
    return Card(
      key: Key('job-card-$workId'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(card.title,
                style: theme.textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
                maxLines: 1),
            const SizedBox(height: 6),
            Text(_status,
                key: Key('job-status-$workId'),
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _progressValue),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                children: [
                  if (_running)
                    TextButton(
                      key: Key('job-pause-$workId'),
                      onPressed: () => coordinator.cancel(workId),
                      child: const Text('Pause'),
                    )
                  else ...[
                    TextButton(
                      key: Key('job-dismiss-$workId'),
                      onPressed: () => coordinator.dismiss(workId),
                      child: const Text('Discard'),
                    ),
                    TextButton(
                      key: Key('job-resume-$workId'),
                      onPressed: () => coordinator.resume(workId),
                      child: Text(card.phase == TranscribePhase.failed
                          ? 'Try again'
                          : 'Resume'),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
