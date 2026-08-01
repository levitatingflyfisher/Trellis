/// Daily review — the study crown, Phase 1: zero-effort resurfacing for
/// extracts and vocab (the word ledger and captures), the gentle two-button
/// on-ramp Readwise-style highlight review is built on. This is NOT the
/// course study flow: course items live in Cards/StudyDao, a table this
/// screen never queries (see DailyReviewDao's doc comment). Soon maps to
/// the sealed scheduler's again; Eventually maps to good — the same
/// scheduleSm2 course sessions use, untouched.
///
/// The front is deliberately plain: a bare ledger word shows just the
/// word, and a capture shows its bound sentence when one exists (or an
/// honest "transcript pending" line otherwise) — there is no
/// extract-authoring flow in this app yet to source a "passage with the
/// focus span blanked" front from (see ADR-0009). This is the degraded,
/// honest version of the spec's zero-authoring ideal, not the full one.
library;

import 'package:flutter/material.dart';
import 'package:study_core/study_core.dart' as study;

import '../../db/database.dart';
import '../intake/paste_intake.dart' show epochDayUtcNow;

class _QueueItem {
  final String sourceType;
  final int sourceId;
  final study.CardState state;
  final String front;
  const _QueueItem(
      {required this.sourceType,
      required this.sourceId,
      required this.state,
      required this.front});
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

    final items = <_QueueItem>[];
    for (final entry in due) {
      final parts = entry.key.split(':');
      final sourceType = parts[0];
      final sourceId = int.parse(parts[1]);
      final front = sourceType == 'ledger'
          ? (words[sourceId]?.word ?? '(word removed)')
          : await _captureFront(sourceId);
      items.add(_QueueItem(
          sourceType: sourceType,
          sourceId: sourceId,
          state: entry.value,
          front: front));
    }
    if (!mounted) return;
    setState(() => _queue = items);
  }

  /// Captures don't carry their own front text — this looks the row up by
  /// scanning the profile's works (small scale for a daily queue), reading
  /// its bound segment's text when one exists.
  Future<String> _captureFront(int captureId) async {
    for (final work in await widget.db.spineDao.worksOf(widget.profileId)) {
      final rows = await widget.db.capturesDao.capturesOf(work.id);
      for (final c in rows) {
        if (c.id != captureId) continue;
        if (c.segmentIdx == null) {
          return 'A captured moment — transcript pending.';
        }
        final segments = await widget.db.spineDao.segmentsOf(work.id);
        final text = segments
            .where((s) => s.idx == c.segmentIdx)
            .map((s) => s.body)
            .firstOrNull;
        return text ?? 'A captured moment.';
      }
    }
    return 'A captured moment.';
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
        [final item, ...] => _reviewCard(item, theme),
      },
    );
  }

  Widget _reviewCard(_QueueItem item, ThemeData theme) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(item.front,
                style: theme.textTheme.headlineSmall,
                textAlign: TextAlign.center),
            const SizedBox(height: 40),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const Key('review-soon'),
                    onPressed: () => _grade(item, study.Grade.again),
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 18)),
                    child: const Text('Soon'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton(
                    key: const Key('review-eventually'),
                    onPressed: () => _grade(item, study.Grade.good),
                    style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 18)),
                    child: const Text('Eventually'),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
}
