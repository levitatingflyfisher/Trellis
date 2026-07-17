import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/providers.dart';
import '../../../core/time.dart';
import '../../study/domain/progress.dart';
import '../../study/presentation/study_session_screen.dart';
import '../data/anki/anki_export.dart';
import '../domain/models.dart';

class CourseMapScreen extends ConsumerStatefulWidget {
  const CourseMapScreen({super.key, required this.course});
  final Course course;

  @override
  ConsumerState<CourseMapScreen> createState() => _CourseMapScreenState();
}

class _CourseMapScreenState extends ConsumerState<CourseMapScreen> {
  Map<String, CardState> _cards = {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      _cards = ref.read(cardRepositoryProvider).load(widget.course.id);
    });
  }

  Future<void> _study() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => StudySessionScreen(course: widget.course),
      ),
    );
    if (!mounted) return;
    _reload(); // mastery may have advanced
  }

  Future<void> _exportAnki() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await exportApkgToTemp(widget.course);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path)], subject: '${widget.course.title} — Anki deck'),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Anki export failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final course = widget.course;
    final today = epochDayNow();

    // Compute each node's progress once, then reuse it for the totals, every
    // tile, and unlock checks — instead of recomputing nodeProgress 2-3×/node
    // (and again per prerequisite) on every rebuild.
    final progressByNode = {
      for (final n in course.nodes) n.id: nodeProgress(n, _cards, today),
    };
    var totalDue = 0;
    var totalItems = 0;
    var totalMastered = 0;
    for (final n in course.nodes) {
      final p = progressByNode[n.id]!;
      // Only count due cards the study session can actually present: a node that
      // is both unstarted and locked contributes nothing to _buildQueue, so it
      // must not inflate the "N due" call-to-action and dead-end on the done screen.
      final started = n.items.any((it) => _cards[it.id] != null);
      if (started || nodeUnlockedFrom(n, progressByNode)) totalDue += p.due;
      totalItems += p.total;
      totalMastered += p.mastered;
    }
    final overall = totalItems == 0 ? 0.0 : totalMastered / totalItems;

    return Scaffold(
      appBar: AppBar(
        title: Text(course.title),
        actions: [
          if (ankiExportSupported)
            IconButton(
              tooltip: 'Export to Anki (.apkg)',
              icon: const Icon(Icons.download_outlined),
              onPressed: _exportAnki,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (course.description.isNotEmpty)
            Text(course.description, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Mastery ${(overall * 100).round()}%',
                        style: theme.textTheme.labelLarge),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(value: overall, minHeight: 8),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          // titleLarge, not titleMedium: OhTheme maps titleMedium to a 14px
          // label, which would rank the section heading below the 16px body.
          Text('Concepts', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          ...course.nodes.map((n) => _NodeTile(
                node: n,
                progress: progressByNode[n.id]!,
                unlocked: nodeUnlockedFrom(n, progressByNode),
                onTap: _study,
              )),
          const SizedBox(height: 80),
        ],
      ),
      floatingActionButton: totalDue == 0
          ? null
          : FloatingActionButton.extended(
              onPressed: _study,
              icon: const Icon(Icons.bolt),
              label: Text('Study  ·  $totalDue due'),
            ),
    );
  }
}

class _NodeTile extends StatelessWidget {
  const _NodeTile({
    required this.node,
    required this.progress,
    required this.unlocked,
    required this.onTap,
  });
  final KnowledgeNode node;
  final NodeProgress progress;
  final bool unlocked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        onTap: unlocked ? onTap : null,
        leading: CircleAvatar(
          backgroundColor: progress.mastery >= 1.0
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceContainerHighest,
          child: Icon(
            progress.mastery >= 1.0
                ? Icons.check
                : (unlocked ? Icons.menu_book_outlined : Icons.lock_outline),
            size: 18,
            color: progress.mastery >= 1.0
                ? theme.colorScheme.onPrimary
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
        title: Text(node.title),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (node.summary.isNotEmpty) Text(node.summary),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(value: progress.mastery, minHeight: 5),
            ),
          ],
        ),
        trailing: progress.hasDue
            ? Chip(
                label: Text('${progress.due}'),
                visualDensity: VisualDensity.compact,
                backgroundColor: theme.colorScheme.primaryContainer,
              )
            : null,
      ),
    );
  }
}
