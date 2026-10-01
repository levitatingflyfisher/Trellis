import 'package:flutter/material.dart';
import 'package:openhearth_design/openhearth_design.dart';

import '../../db/database.dart';
import '../settings/theme_preference.dart';
import '../shared/capped_body.dart';
import 'player_controller.dart';

/// The Queue tab: what's queued, in play order, with a remove verb per row
/// and drag to reorder. A tab root, so it has no back arrow; the mini
/// bar's queue button switches to it.
class QueueScreen extends StatefulWidget {
  final AppDatabase db;
  final Profile profile;

  /// The shell's player. Finishing an episode takes it off the queue while
  /// this tab may be the one on screen, so a change of what's playing
  /// reloads the list.
  final PlayerController? player;

  /// Opens History, which the bar shows as a visible door: the queue is
  /// what plays next, history is what played.
  final Future<void> Function()? onOpenHistory;
  const QueueScreen(
      {super.key,
      required this.db,
      required this.profile,
      this.player,
      this.onOpenHistory});

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  List<QueueEntry>? _entries;

  int? _playingId;

  @override
  void initState() {
    super.initState();
    _playingId = widget.player?.current?.id;
    widget.player?.addListener(_onPlayer);
    _load();
  }

  @override
  void dispose() {
    widget.player?.removeListener(_onPlayer);
    super.dispose();
  }

  // The player notifies on every tick; only a change of work can have
  // moved the queue.
  void _onPlayer() {
    final id = widget.player?.current?.id;
    if (id == _playingId) return;
    _playingId = id;
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
    final theme = ThemePreferenceScope.maybeOf(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Queue'),
        actions: [
          OhBarActions(children: [
            if (widget.onOpenHistory case final open?)
              OhBarAction(
                key: const Key('queue-history'),
                icon: Icons.history,
                label: 'History',
                tooltip: 'History',
                onPressed: () async {
                  await open();
                  // Playing from History may have moved the queue.
                  await _load();
                },
              ),
            // A tab like the others, so the theme is in its menu too.
            if (theme != null)
              OhBarOverflow<String>(
                key: const Key('queue-more'),
                onSelected: (v) => chooseThemeFromMenu(theme, v),
                itemBuilder: (_) => themeMenuItems(theme, divided: false),
              ),
          ]),
        ],
      ),
      body: CappedBody(child: switch (entries) {
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
      }),
    );
  }
}
