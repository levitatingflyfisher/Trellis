import 'package:flutter/material.dart';

import '../../db/database.dart';

/// The Up Next queue's own small view: what's queued, in play order, with
/// a remove verb per row and drag to reorder. Reachable from the mini
/// player bar.
class QueueScreen extends StatefulWidget {
  final AppDatabase db;
  final Profile profile;
  const QueueScreen({super.key, required this.db, required this.profile});

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  List<QueueEntry>? _entries;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await widget.db.queueDao.queueEntriesOf(widget.profile.id);
    if (!mounted) return;
    setState(() => _entries = entries);
  }

  Future<void> _remove(QueueEntry e) async {
    await widget.db.queueDao
        .remove(profileId: widget.profile.id, workId: e.work.id);
    await _load();
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    final entries = _entries;
    if (entries == null) return;
    if (newIndex > oldIndex) newIndex -= 1; // ReorderableListView's own law
    final moved = entries[oldIndex];
    await widget.db.queueDao.reorder(
        profileId: widget.profile.id,
        workId: moved.work.id,
        newPosition: newIndex);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(title: const Text('Up Next')),
      body: switch (entries) {
        null => const Center(child: CircularProgressIndicator()),
        [] => const Center(child: Text('Nothing queued yet.')),
        _ => ReorderableListView.builder(
            itemCount: entries.length,
            onReorder: _reorder,
            itemBuilder: (_, i) {
              final e = entries[i];
              return ListTile(
                key: Key('queue-item-${e.work.id}'),
                leading: const Icon(Icons.drag_handle),
                title: Text(e.work.title,
                    overflow: TextOverflow.ellipsis, maxLines: 1),
                trailing: IconButton(
                  key: Key('queue-remove-${e.work.id}'),
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close),
                  onPressed: () => _remove(e),
                ),
              );
            },
          ),
      },
    );
  }
}
