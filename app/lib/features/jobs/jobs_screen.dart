/// The one list of every long job: what each is doing, how far it got,
/// and, if it stopped, why, beside the one verb that helps.
library;

import 'package:flutter/material.dart';

import '../dsp/dsp_coordinator.dart';
import '../feeds/episode_download_coordinator.dart';
import '../models/format.dart';
import '../shared/capped_body.dart';
import '../transcribe/job_cards.dart';
import 'job_center.dart';

class JobsScreen extends StatelessWidget {
  final JobCenter jobs;
  const JobsScreen({super.key, required this.jobs});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Jobs')),
      body: CappedBody(
        child: ListenableBuilder(
          listenable: jobs,
          builder: (context, _) {
            final downloads = jobs.downloads;
            final dsp = jobs.dsp;
            final children = <Widget>[
              for (final c in jobs.transcribe.cards)
                TranscribeJobCard(coordinator: jobs.transcribe, card: c),
              if (downloads != null)
                for (final e in jobs.standaloneDownloads)
                  DownloadJobCard(
                      coordinator: downloads, workId: e.workId, state: e.state),
              if (dsp != null)
                for (final c in dsp.cards) _DspJobCard(coordinator: dsp, card: c),
            ];
            if (children.isEmpty) return const _NothingRunning();
            return ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: children,
            );
          },
        ),
      ),
    );
  }
}

class _NothingRunning extends StatelessWidget {
  const _NothingRunning();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      key: const Key('jobs-empty'),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'Nothing running right now. Downloads and transcriptions show up '
          'here while they work, and stay here if they stop, so you can '
          'pick them back up.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge,
        ),
      ),
    );
  }
}

/// "12 MB of 48 MB", or just "12 MB" when the server never said.
String bytesProgress(int? received, int? total) {
  final got = formatBytes(received ?? 0);
  return total == null ? got : '$got of ${formatBytes(total)}';
}

/// One plain line for a download's state; shared with the Inbox row.
String downloadStatus(EpisodeDownloadState s) {
  if (s.failed) return 'Download didn’t finish. ${s.error}';
  final bytes = bytesProgress(s.receivedBytes, s.totalBytes);
  if (s.paused) {
    return (s.receivedBytes ?? 0) == 0
        ? 'Download paused'
        : 'Download paused: $bytes so far';
  }
  return s.receivedBytes == null ? 'Starting download…' : 'Downloading: $bytes';
}

double? downloadFraction(EpisodeDownloadState s) {
  final total = s.totalBytes;
  if (total == null || total == 0) return s.downloading ? null : 0;
  return ((s.receivedBytes ?? 0) / total).clamp(0, 1).toDouble();
}

class DownloadJobCard extends StatelessWidget {
  final EpisodeDownloadCoordinator coordinator;
  final int workId;
  final EpisodeDownloadState state;
  const DownloadJobCard(
      {super.key,
      required this.coordinator,
      required this.workId,
      required this.state});

  @override
  Widget build(BuildContext context) {
    return _JobCardFrame(
      cardKey: Key('download-card-$workId'),
      title: state.title,
      status: downloadStatus(state),
      progress: downloadFraction(state),
      actions: [
        if (state.downloading)
          TextButton(
            key: Key('download-pause-$workId'),
            onPressed: () => coordinator.cancel(workId),
            child: const Text('Pause'),
          )
        else ...[
          TextButton(
            key: Key('download-discard-$workId'),
            onPressed: () => coordinator.dismiss(workId),
            child: const Text('Discard'),
          ),
          TextButton(
            key: Key('download-retry-$workId'),
            onPressed: () => coordinator.resume(workId),
            child: Text(state.failed ? 'Try again' : 'Resume'),
          ),
        ],
      ],
    );
  }
}

class _DspJobCard extends StatelessWidget {
  final DspCoordinator coordinator;
  final DspCardState card;
  const _DspJobCard({required this.coordinator, required this.card});

  @override
  Widget build(BuildContext context) {
    final workId = card.workId;
    final status = switch (card.phase) {
      DspPhase.measuring => 'Tidying the audio: measuring…',
      DspPhase.processing => 'Tidying the audio: trimming silences…',
      DspPhase.paused => 'Audio tidy-up paused. It starts over when resumed.',
      DspPhase.failed => 'Audio tidy-up didn’t finish. ${card.error ?? ''}',
      DspPhase.ineligible =>
        'Audio left as it is: this episode has a transcript, and trimming '
            'would move its timings.',
    };
    final running =
        card.phase == DspPhase.measuring || card.phase == DspPhase.processing;
    return _JobCardFrame(
      cardKey: Key('dsp-card-$workId'),
      title: card.title,
      status: status.trimRight(),
      progress: running ? null : 0,
      actions: [
        if (running)
          TextButton(
            key: Key('dsp-pause-$workId'),
            onPressed: () => coordinator.cancel(workId),
            child: const Text('Pause'),
          )
        else ...[
          TextButton(
            key: Key('dsp-discard-$workId'),
            onPressed: () => coordinator.dismiss(workId),
            child: Text(card.phase == DspPhase.ineligible ? 'OK' : 'Discard'),
          ),
          if (card.phase != DspPhase.ineligible)
            TextButton(
              key: Key('dsp-retry-$workId'),
              onPressed: () => coordinator.resume(workId),
              child: Text(card.phase == DspPhase.failed ? 'Try again' : 'Resume'),
            ),
        ],
      ],
    );
  }
}

class _JobCardFrame extends StatelessWidget {
  final Key cardKey;
  final String title;
  final String status;
  final double? progress;
  final List<Widget> actions;
  const _JobCardFrame({
    required this.cardKey,
    required this.title,
    required this.status,
    required this.progress,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: cardKey,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: theme.textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
                maxLines: 1),
            const SizedBox(height: 6),
            Text(status, style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(children: actions),
            ),
          ],
        ),
      ),
    );
  }
}
