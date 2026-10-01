/// "Storage by item" (1.5.8): every work that holds files or text on this
/// device, biggest first, with what each part costs and a delete for each.
/// Opened from Models & storage, whose own panel clears whole caches;
/// here the reader frees space one work at a time and keeps the rest.
library;

import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../../services/device_services.dart';
import '../episodes/episode_actions.dart';
import '../models/format.dart';
import '../shared/capped_body.dart';
import 'work_storage.dart';

class StorageByItemScreen extends StatefulWidget {
  final AppDatabase db;
  final DeviceServices services;

  /// Whose works are listed: another reader's titles stay theirs.
  final int profileId;

  /// Removes a download the way every list does, keeping one that is
  /// playing or being transcribed.
  final EpisodeActions? actions;

  const StorageByItemScreen({
    super.key,
    required this.db,
    required this.services,
    required this.profileId,
    this.actions,
  });

  @override
  State<StorageByItemScreen> createState() => _StorageByItemScreenState();
}

class _StorageByItemScreenState extends State<StorageByItemScreen> {
  List<WorkStorage>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items =
        await loadWorkStorage(widget.db,
            services: widget.services, profileId: widget.profileId);
    if (mounted) setState(() => _items = items);
  }

  Future<void> _delete(WorkStorage w, StoredPart p) async {
    if (!await confirmDeletePart(context, w, p)) return;
    final message = await deletePart(w, p,
        db: widget.db, services: widget.services, actions: widget.actions);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message), persist: false));
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Storage by item')),
      body: CappedBody(
        child: items == null
            ? const Center(child: CircularProgressIndicator())
            : items.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Nothing stored yet. Downloads, transcripts and '
                        'translations show here, item by item.',
                        key: const Key('storage-by-item-empty'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: 16),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text(
                          'Biggest first. Text sizes are about: the database '
                          'file gives the space back over time.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      for (final w in items) _card(w),
                    ],
                  ),
      ),
    );
  }

  Widget _card(WorkStorage w) {
    final theme = Theme.of(context);
    return Card(
      key: Key('stored-work-${w.workId}'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              w.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall,
            ),
            Text(formatBytes(w.bytes), style: theme.textTheme.bodySmall),
            for (final p in w.parts) _partRow(w, p),
          ],
        ),
      ),
    );
  }

  /// Text beside its button while it fits; the button wraps below at
  /// large text rather than squeezing the words.
  Widget _partRow(WorkStorage w, StoredPart p) {
    final theme = Theme.of(context);
    return Padding(
      key: Key('stored-${p.keyName}-${w.workId}'),
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(p.label, style: theme.textTheme.bodyMedium),
              Text(p.sizeLabel, style: theme.textTheme.bodySmall),
            ],
          ),
          // The short word fits the row; the tooltip and screen reader
          // get the whole act.
          Tooltip(
            message: p.deleteLabel,
            child: TextButton(
              key: Key('stored-delete-${p.keyName}-${w.workId}'),
              onPressed: () => _delete(w, p),
              child: Text(p.kind == StoredKind.audio ? 'Remove' : 'Delete'),
            ),
          ),
        ],
      ),
    );
  }
}
