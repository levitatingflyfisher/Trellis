/// Daily review — the study crown, Phase 1: zero-effort resurfacing for
/// extracts and vocab (the word ledger and captures), the gentle two-button
/// on-ramp Readwise-style highlight review is built on. This is NOT the
/// course study flow: course items live in Cards/StudyDao, a table this
/// screen never queries (see DailyReviewDao's doc comment). Soon maps to
/// the sealed scheduler's again; Eventually maps to good — the same
/// scheduleSm2 course sessions use, untouched.
///
/// The front is deliberately plain: a bare ledger word shows just the
/// word. A capture's front is built from two independent pieces (Campaign
/// 9 Phase 3, "the study screen tells you what happened" — user: "nothing
/// happened when I clicked either [button]"): a byline that ALWAYS names
/// the work and the mm:ss it was taken at (so two untranscribed captures
/// never look identical, which is what made grading feel like a no-op),
/// and a headline that is the bound sentence once one can be resolved, or
/// an honest, visually SECONDARY "Transcript pending." line otherwise —
/// there is no extract-authoring flow in this app yet to source a
/// "passage with the focus span blanked" front from (see ADR-0009). This
/// is the degraded, honest version of the spec's zero-authoring ideal,
/// not the full one.
library;

import 'package:flutter/material.dart';
import 'package:loom_core/loom_core.dart' as core;
import 'package:study_core/study_core.dart' as study;

import '../../db/database.dart';
import '../intake/paste_intake.dart' show epochDayUtcNow;
import '../models/format.dart' show formatClock;

class _QueueItem {
  final String sourceType;
  final int sourceId;
  final study.CardState state;

  /// The word (ledger) or the resolved sentence (capture, once one can be
  /// found) — empty for a capture with no transcript yet, in which case
  /// [pending] carries the story instead.
  final String headline;

  /// Null for a ledger word (nothing to attribute it to). For a capture,
  /// ALWAYS set — "Work title · mm:ss" — regardless of whether a
  /// transcript exists, which is what makes two otherwise-identical
  /// pending captures visibly distinct cards.
  final String? byline;

  final bool pending;

  const _QueueItem({
    required this.sourceType,
    required this.sourceId,
    required this.state,
    required this.headline,
    this.byline,
    this.pending = false,
  });

  Key get key => ValueKey('$sourceType:$sourceId');
}

class DailyReviewScreen extends StatefulWidget {
  final AppDatabase db;
  final int profileId;
  const DailyReviewScreen({super.key, required this.db, required this.profileId});

  @override
  State<DailyReviewScreen> createState() => _DailyReviewScreenState();
}

class _DailyReviewScreenState extends State<DailyReviewScreen> {
  late final int _today = epochDayUtcNow();
  List<_QueueItem>? _queue;
  int _reviewed = 0;

  /// Fixed at load — the "M" of the "N of M" progress counter. [_queue]'s
  /// own length is "N" (it only ever shrinks), so the counter needs no
  /// separate mutable state of its own.
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await widget.db.dailyReviewDao.loadAll(widget.profileId, _today);
    final due = all.entries.where((e) => e.value.isDue(_today)).toList();

    final words = {
      for (final w in await widget.db.ledgerDao.wordsOf(widget.profileId))
        w.id: w
    };
    // One profile-scoped query rather than the old per-capture scan across
    // every work — captures are already keyed by id here.
    final captures = {
      for (final c in await widget.db.capturesDao.capturesOfProfile(widget.profileId))
        c.id: c
    };

    final items = <_QueueItem>[];
    for (final entry in due) {
      final parts = entry.key.split(':');
      final sourceType = parts[0];
      final sourceId = int.parse(parts[1]);
      if (sourceType == 'ledger') {
        items.add(_QueueItem(
            sourceType: sourceType,
            sourceId: sourceId,
            state: entry.value,
            headline: words[sourceId]?.word ?? '(word removed)'));
        continue;
      }
      final capture = captures[sourceId];
      if (capture == null) {
        items.add(_QueueItem(
            sourceType: sourceType,
            sourceId: sourceId,
            state: entry.value,
            headline: '',
            byline: 'A captured moment',
            pending: true));
        continue;
      }
      final details = await _captureDetails(capture);
      items.add(_QueueItem(
          sourceType: sourceType,
          sourceId: sourceId,
          state: entry.value,
          headline: details.sentence ?? '',
          byline: details.byline,
          pending: details.sentence == null));
    }
    if (!mounted) return;
    setState(() {
      _queue = items;
      _total = items.length;
    });
  }

  /// Resolves a capture's byline (always) and sentence (only when the
  /// work's alignments can place [capture.positionMs] in one) AT RENDER
  /// TIME, straight from the spine — never from a backfilled
  /// [Captures.segmentIdx] column, so a capture taken before transcription
  /// finished shows its sentence the moment alignments exist, with no
  /// separate backfill pass required to catch this one screen up.
  Future<({String byline, String? sentence})> _captureDetails(
      CaptureRow capture) async {
    final work = await widget.db.spineDao.workById(capture.workId);
    final title = work?.title ?? 'A captured moment';
    final byline = '$title · ${formatClock(capture.positionMs)}';
    final alignmentRows = await widget.db.spineDao.alignmentsOf(capture.workId);
    if (alignmentRows.isEmpty) return (byline: byline, sentence: null);
    final spine = core.Spine(
      segments: const [],
      layers: const [],
      alignments: [
        for (final a in alignmentRows)
          core.Alignment(
              segmentIdx: a.segmentIdx, tStartMs: a.tStartMs, tEndMs: a.tEndMs),
      ],
    );
    final segmentIdx =
        spine.positionAtAudioTime(capture.positionMs).segmentIdx;
    final segments = await widget.db.spineDao.segmentsOf(capture.workId);
    final sentence =
        segments.where((s) => s.idx == segmentIdx).map((s) => s.body).firstOrNull;
    return (byline: byline, sentence: sentence);
  }

  Future<void> _grade(_QueueItem item, study.Grade grade) async {
    final next = study.scheduleSm2(item.state, grade, _today);
    await widget.db.dailyReviewDao.recordGrade(
        profileId: widget.profileId,
        sourceType: item.sourceType,
        sourceId: item.sourceId,
        after: next);
    if (!mounted) return;
    setState(() {
      _queue!.removeWhere((q) =>
          q.sourceType == item.sourceType && q.sourceId == item.sourceId);
      _reviewed++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final queue = _queue;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Daily review')),
      body: switch (queue) {
        null => const Center(child: CircularProgressIndicator()),
        [] => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                  _reviewed > 0
                      ? 'Nothing to review right now — you reviewed '
                          '$_reviewed. Come back later; resurfacing happens '
                          'on its own schedule.'
                      : 'Nothing to review right now — resurfacing happens '
                          'on its own schedule. Keep a word while you read, '
                          'or a moment while you listen, and it will show '
                          'up here.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge),
            ),
          ),
        [final item, ...] => Column(
            children: [
              // Progress feedback (Campaign 9 Phase 3): grading to a card
              // that LOOKS the same as the one before it read as a no-op —
              // this ticks down every grade, visible proof something moved.
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text('${queue.length} of $_total',
                    key: const Key('review-progress'),
                    style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
              // A long title/sentence at large text scale on a narrow
              // screen can outgrow the available height — LayoutBuilder +
              // a min-height-constrained SingleChildScrollView keeps the
              // card centered when it fits and lets it scroll instead of
              // overflowing when it doesn't (the house accessibility-
              // overflow law: verified, not assumed, at 320dp/2x).
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints:
                          BoxConstraints(minHeight: constraints.maxHeight),
                      child: Center(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          child: _reviewCard(item, theme),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
      },
    );
  }

  Widget _reviewCard(_QueueItem item, ThemeData theme) => Padding(
        key: item.key,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (item.byline != null) ...[
              Text(item.byline!,
                  key: const Key('capture-byline'),
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
            ],
            if (item.headline.isNotEmpty)
              Text(item.headline,
                  style: theme.textTheme.headlineSmall,
                  textAlign: TextAlign.center)
            else if (item.pending)
              Text('Transcript pending.',
                  key: const Key('capture-pending'),
                  style: theme.textTheme.bodyLarge?.copyWith(
                      fontStyle: FontStyle.italic,
                      color: theme.colorScheme.onSurfaceVariant),
                  textAlign: TextAlign.center),
            const SizedBox(height: 40),
            Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      OutlinedButton(
                        key: const Key('review-soon'),
                        onPressed: () => _grade(item, study.Grade.again),
                        style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 18)),
                        child: const Text('Show me again soon'),
                      ),
                      const SizedBox(height: 4),
                      Text("You'll see this again before it sticks.",
                          style: theme.textTheme.bodySmall,
                          textAlign: TextAlign.center),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    children: [
                      FilledButton(
                        key: const Key('review-eventually'),
                        onPressed: () => _grade(item, study.Grade.good),
                        style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 18)),
                        child: const Text("I've got this"),
                      ),
                      const SizedBox(height: 4),
                      Text("This one steps back — it won't come up again "
                          'for a while.',
                          style: theme.textTheme.bodySmall,
                          textAlign: TextAlign.center),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      );
}
