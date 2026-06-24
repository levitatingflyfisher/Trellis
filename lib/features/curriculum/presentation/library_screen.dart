import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../domain/models.dart';
import 'course_map_screen.dart';

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final courses = ref.watch(coursesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trellis'),
        actions: [
          IconButton(
            tooltip: 'Import a .ohcourse',
            icon: const Icon(Icons.add),
            onPressed: () => _import(context, ref),
          ),
        ],
      ),
      body: courses.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load courses:\n$e')),
        data: (list) => list.isEmpty
            ? const _Empty()
            : ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: list.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _CourseCard(course: list[i]),
              ),
      ),
    );
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    String? error;
    final imported = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Import course'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Paste a .ohcourse JSON (from the trellis-author skill):'),
                const SizedBox(height: 8),
                TextField(
                  controller: controller,
                  minLines: 6,
                  maxLines: 12,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: '{ "schemaVersion": "1.0", ... }',
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                try {
                  await ref.read(courseRepositoryProvider).importFromJson(controller.text);
                  if (ctx.mounted) Navigator.pop(ctx, true);
                } on FormatException catch (e) {
                  setState(() => error = e.message);
                } catch (e) {
                  setState(() => error = '$e');
                }
              },
              child: const Text('Import'),
            ),
          ],
        ),
      ),
    );
    if (imported == true) {
      ref.invalidate(coursesProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Course imported')),
        );
      }
    }
  }
}

class _CourseCard extends StatelessWidget {
  const _CourseCard({required this.course});
  final Course course;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = [
      if (course.subject.isNotEmpty) course.subject,
      if (course.level.isNotEmpty) course.level,
      '${course.nodes.length} concepts',
    ].join('  ·  ');
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        title: Text(course.title, style: theme.textTheme.titleMedium),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (course.subtitle.isNotEmpty) Text(course.subtitle),
            const SizedBox(height: 4),
            Text(meta, style: theme.textTheme.bodySmall),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => CourseMapScreen(course: course)),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.school_outlined, size: 48),
              const SizedBox(height: 12),
              Text('No courses yet',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text(
                'Tap + to paste a .ohcourse, or generate one with the '
                'trellis-author skill.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
}
