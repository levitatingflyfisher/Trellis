import 'package:flutter/material.dart';
import 'package:openhearth_design/openhearth_design.dart';

import '../../db/database.dart';
import '../episodes/episode_actions.dart';
import '../reader/reader_doors.dart';
import '../settings/theme_preference.dart';
import '../shared/capped_body.dart';
import '../works/work_menu.dart';
import '../works/work_open.dart';
import '../works/work_row.dart';
import 'player_controller.dart';

/// The Queue tab: what's queued, in play order, in the same rows as every
/// other list, with a drag handle to reorder and Remove from Queue at the
/// end of each row's menu. A tab root, so it has no back arrow; the mini
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

  /// What the rows can do (queue, download, mark played) and what they
  /// know (artwork, downloads); the shell's own, so the menu matches
  /// Latest's. Null builds a bare one over [player].
  final EpisodeActions? actions;

  /// How a row opens a text or a transcript.
  final ReaderDoors? readerDoors;

  const QueueScreen(
      {super.key,
      required this.db,
      required this.profile,
      this.player,
      this.onOpenHistory,
      this.actions,
      this.readerDoors});

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  List<QueueEntry>? _entries;
  WorkListState _rowState = WorkListState.empty;

  int? _playingId;

  late final EpisodeActions _actions = widget.actions ??
      EpisodeActions(
          db: widget.db, profileId: widget.profile.id, player: widget.player);

  late final WorkDoors _doors = WorkDoors(
      db: widget.db,
      profileId: widget.profile.id,
      readerDoors: widget.readerDoors ?? ReaderDoors(player: widget.player),
      actions: _actions);

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
    final rowState = await WorkListState.load(widget.db, widget.profile.id,
        entries: [for (final e in entries) (work: e.work, episode: e.episode)]);
    if (!mounted) return;
    _actions.forgetArtwork();
    setState(() {
      _entries = entries;
      _rowState = rowState;
    });
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
            // The row's own handle drags at once; a long press anywhere
            // on the row drags too. No second, default handle.
            buildDefaultDragHandles: false,
            itemBuilder: (_, i) => ReorderableDelayedDragStartListener(
              key: Key('queue-item-${entries[i].work.id}'),
              index: i,
              child: _row(entries[i], i),
            ),
          ),
      }),
    );
  }

  Widget _row(QueueEntry e, int index) {
    final work = e.work;
    final episode = e.episode;
    final entry = (work: work, episode: episode);
    final isAudio = episode?.enclosureUrl != null || work.kind == 'audiobook';
    return WorkRow(
      work: work,
      episode: episode,
      facts: WorkRowFacts.of(work, episode, _rowState,
              downloaded: episode != null && _actions.isDownloaded(episode))
          .withoutQueued(),
      showTitle: e.feedTitle,
      artwork: episode == null ? null : _actions.artworkFor(episode),
      onTap: () async {
        final removal =
            await _doors.open(context, entry, showTitle: e.feedTitle);
        await _load();
        // Removed from its page: reload once the Undo goes.
        removal?.then((_) => mounted ? _load() : null);
      },
      onPlay: isAudio && widget.player != null
          ? () async {
              await _doors.play(work);
              await _load();
            }
          : null,
      onRead: _doors.canRead(entry)
          ? () async {
              await _doors.readFromRow(context, entry);
              await _load();
            }
          : null,
      menuBuilder: (_) => workMenuItems(_actions, entry,
          transcribed: _rowState.transcribed.contains(work.id), extras: [
        PopupMenuItem(
            key: Key('queue-remove-${work.id}'),
            value: 'remove',
            child: const Text('Remove from Queue')),
      ]),
      onMenu: (choice) async {
        if (choice == 'remove') return _remove(e);
        await _actions.handleShared(context, choice, entry,
            showTitle: e.feedTitle);
        await _load();
      },
      trailing: ReorderableDragStartListener(
        index: index,
        child: SizedBox(
          key: Key('queue-handle-${work.id}'),
          width: 48,
          height: 48,
          child: Semantics(
            label: 'Drag to reorder',
            child: const Icon(Icons.drag_handle),
          ),
        ),
      ),
    );
  }
}
