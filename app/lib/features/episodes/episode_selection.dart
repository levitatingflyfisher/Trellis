/// Multi-select and the clean-up's bulk actions (ADR-0016 section 5), one
/// home for every list that uses [WorkRow], so Latest, the podcast
/// page, History and search can't drift apart.
///
/// The session it serves is "clean up what I didn't listen to". Nothing
/// here counts what was left unplayed or asks the listener to act on it:
/// the bar only reports what the listener just did, with the way back.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:openhearth_design/openhearth_design.dart';

import '../../db/bulk_episodes.dart';
import 'episode_actions.dart';

enum BulkAction { markPlayed, markUnplayed, letPass, removeDownload, addToQueue }

/// Which rows are selected, and what the list on screen holds. The list
/// that is showing sets [universe] and [reload], so a bar owned by the
/// screen (History inside search, say) acts on the right rows.
class EpisodeSelection extends ChangeNotifier {
  bool _active = false;
  final Set<int> _ids = {};

  List<EpisodeEntry> _universe = const [];
  bool _disposed = false;

  /// The selectable rows on screen, in their order. Setting it drops
  /// selected ids no longer on screen (a reload, a filter), so the count
  /// and every action cover only rows the listener can see.
  List<EpisodeEntry> get universe => _universe;
  set universe(List<EpisodeEntry> rows) {
    _universe = rows;
    final before = _ids.length;
    _ids.retainAll({for (final e in rows) e.work.id});
    // Lists set this mid-build, where notifying is not allowed; the bar
    // catches up on the next turn.
    if (_ids.length != before) {
      scheduleMicrotask(() {
        if (!_disposed) notifyListeners();
      });
    }
  }

  /// Reloads the list on screen after a bulk change or its Undo.
  Future<void> Function()? reload;

  bool get active => _active;
  int get count => _ids.length;
  bool contains(int workId) => _ids.contains(workId);

  List<EpisodeEntry> get selected => [
        for (final e in universe)
          if (_ids.contains(e.work.id)) e,
      ];

  /// Enters selection, optionally with one row already chosen (the
  /// long-press path); the bar's Select item enters with none.
  void enter([int? workId]) {
    _active = true;
    if (workId != null) _ids.add(workId);
    notifyListeners();
  }

  void toggle(int workId) {
    if (!_ids.remove(workId)) _ids.add(workId);
    notifyListeners();
  }

  void selectAll() {
    _ids.addAll([for (final e in universe) e.work.id]);
    notifyListeners();
  }

  void exit() {
    if (!_active && _ids.isEmpty) return;
    _active = false;
    _ids.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// A screen's selection, its bar, and the actions behind the bar.
class EpisodeBulk {
  final EpisodeActions actions;
  final EpisodeSelection selection;
  final OhUndoController undo;

  EpisodeBulk({
    required this.actions,
    required this.selection,
    required this.undo,
  });

  BulkEpisodes get _store => BulkEpisodes(actions.db);

  int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  Future<void> _reload() async => selection.reload?.call();

  /// The contextual bar that replaces a screen's own while selecting.
  PreferredSizeWidget bar(BuildContext context) {
    final n = selection.count;
    final some = n > 0;
    return AppBar(
      key: const Key('selection-bar'),
      leading: IconButton(
        key: const Key('selection-done'),
        tooltip: 'Done selecting',
        icon: const Icon(Icons.close),
        onPressed: selection.exit,
      ),
      title: Text(n == 0 ? 'Select episodes' : '$n selected'),
      actions: [
        OhBarActions(children: [
          OhBarAction(
            key: const Key('selection-all'),
            icon: Icons.select_all,
            label: 'Select all',
            onPressed: selection.selectAll,
          ),
          OhBarAction(
            key: const Key('bulk-mark-played'),
            icon: Icons.done_all,
            label: 'Mark played',
            onPressed:
                some ? () => run(context, BulkAction.markPlayed) : null,
          ),
          OhBarOverflow<BulkAction>(
            key: const Key('selection-more'),
            enabled: some,
            onSelected: (a) => run(context, a),
            itemBuilder: (_) => [
              const PopupMenuItem(
                  key: Key('bulk-mark-unplayed'),
                  value: BulkAction.markUnplayed,
                  child: Text('Mark unplayed')),
              const PopupMenuItem(
                  key: Key('bulk-let-pass'),
                  value: BulkAction.letPass,
                  child: Text('Let it pass')),
              const PopupMenuItem(
                  key: Key('bulk-up-next'),
                  value: BulkAction.addToQueue,
                  child: Text('Add to Queue')),
              if (actions.canDownload)
                const PopupMenuItem(
                    key: Key('bulk-remove-download'),
                    value: BulkAction.removeDownload,
                    child: Text('Remove download')),
            ],
          ),
        ]),
      ],
    );
  }

  /// Back and Escape leave selection before they leave the screen.
  Widget scope({required Widget child}) =>
      _SelectionScope(selection: selection, child: child);

  Future<void> run(BuildContext context, BulkAction action) async {
    final chosen = selection.selected;
    final audio = [
      for (final e in chosen)
        if (e.episode.enclosureUrl != null) e,
    ];
    final messenger = ScaffoldMessenger.of(context);
    if (action == BulkAction.removeDownload) {
      final ({int removed, int cancelled, int kept}) result;
      try {
        result = await actions.removeDownloads(chosen);
      } catch (_) {
        _failed(messenger, 'Couldn’t remove every download. Try again.');
        await _reload();
        return;
      }
      selection.exit();
      await _reload();
      // No Undo: the bytes are gone. Saying so beats an Undo that would
      // have to download them again.
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
          key: const Key('bulk-removed'),
          persist: false,
          content: Text(removedMessage(result)),
        ));
      return;
    }
    final ids = [for (final e in audio) e.work.id];
    final BulkChange change;
    try {
      change = switch (action) {
        BulkAction.markPlayed => await _store.markPlayed(ids, nowMs: _nowMs),
        BulkAction.markUnplayed => await _store.markUnplayed(ids,
            profileId: actions.profileId),
        BulkAction.letPass => await _store
            .letPass([for (final e in chosen) e.work.id], nowMs: _nowMs),
        BulkAction.addToQueue => await _store.addToQueue(_bingeOrder(audio),
            profileId: actions.profileId, nowMs: _nowMs),
        BulkAction.removeDownload => throw StateError('handled above'),
      };
    } catch (_) {
      // The write is one transaction, so a failure left nothing half done;
      // the selection stays for another try.
      _failed(messenger, 'Couldn’t change these episodes. Nothing was '
          'changed.');
      return;
    }
    selection.exit();
    await _reload();
    if (!context.mounted) return;
    _offerUndo(messenger, change, _message(action, change.count));
  }

  /// Queueing a selection plays oldest to newest by publish date,
  /// whatever order the list shows (coordinator ruling: binge order).
  static List<int> _bingeOrder(List<EpisodeEntry> entries) {
    final sorted = [...entries]..sort((a, b) {
        final by = a.episode.publishedAtMs.compareTo(b.episode.publishedAtMs);
        return by != 0 ? by : a.work.id.compareTo(b.work.id);
      });
    return [for (final e in sorted) e.work.id];
  }

  static void _failed(ScaffoldMessengerState messenger, String text) =>
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
            key: const Key('bulk-failed'),
            persist: false,
            content: Text(text)));

  /// What Remove download did, in words: files removed, downloads
  /// stopped part way, and episodes in use that kept theirs.
  static String removedMessage(
      ({int removed, int cancelled, int kept}) r) {
    final parts = <String>[
      if (r.removed == 1) 'Removed 1 download.',
      if (r.removed > 1) 'Removed ${r.removed} downloads.',
      if (r.cancelled == 1) 'Stopped 1 download in progress.',
      if (r.cancelled > 1) 'Stopped ${r.cancelled} downloads in progress.',
      if (r.removed + r.cancelled > 0) 'You can download again any time.',
      if (r.removed + r.cancelled == 0 && r.kept > 0) 'Nothing removed.',
      if (r.kept == 1)
        'The episode playing, transcribing or processing keeps its '
            'download.',
      if (r.kept > 1)
        '${r.kept} episodes playing, transcribing or processing keep '
            'their downloads.',
    ];
    return parts.isEmpty ? 'None of these were downloaded.' : parts.join(' ');
  }

  static String _message(BulkAction action, int n) {
    final eps = n == 1 ? '1 episode' : '$n episodes';
    final items = n == 1 ? '1 item' : '$n items';
    return switch (action) {
      BulkAction.markPlayed => 'Marked $eps played',
      BulkAction.markUnplayed => 'Marked $eps unplayed',
      BulkAction.letPass => 'Let $items pass',
      BulkAction.addToQueue => 'Added $eps to the Queue',
      BulkAction.removeDownload => '',
    };
  }

  void _offerUndo(
      ScaffoldMessengerState messenger, BulkChange change, String message) {
    if (!change.changed) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(
            key: Key('bulk-nothing'),
            persist: false,
            content: Text('Nothing needed changing.')));
      return;
    }
    undo.show(
      message: message,
      onUndo: () async {
        await change.undo();
        await _reload();
      },
    );
  }

  /// "Mark everything older as played": [older] is already the rows that
  /// would change. Asks first with the count, since one tap reaches far
  /// past what is on screen.
  Future<void> markOlderPlayed(
      BuildContext context, List<EpisodeEntry> older) async {
    final n = older.length;
    if (n == 0) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showOhConfirm(
      context,
      title: n == 1
          ? 'Mark 1 older episode as played?'
          : 'Mark $n older episodes as played?',
      message: 'History keeps only what you actually listened to, so '
          'these won’t appear there.',
      confirmLabel: 'Mark $n played',
    );
    if (!ok) return;
    final BulkChange change;
    try {
      change = await _store
          .markPlayed([for (final e in older) e.work.id], nowMs: _nowMs);
    } catch (_) {
      _failed(messenger, 'Couldn’t mark these played. Nothing was changed.');
      return;
    }
    await _reload();
    if (!context.mounted) return;
    _offerUndo(messenger, change, _message(BulkAction.markPlayed, change.count));
  }
}

/// The audio rows a "mark older as played" would change: unplayed ones
/// with something to play. Articles have no played state.
List<EpisodeEntry> unplayedAudio(Iterable<EpisodeEntry> entries) => [
      for (final e in entries)
        if (e.episode.enclosureUrl != null && e.episode.finishedAtMs == null)
          e,
    ];

class _SelectionScope extends StatefulWidget {
  final EpisodeSelection selection;
  final Widget child;
  const _SelectionScope({required this.selection, required this.child});

  @override
  State<_SelectionScope> createState() => _SelectionScopeState();
}

class _SelectionScopeState extends State<_SelectionScope> {
  final _focus = FocusNode(debugLabel: 'episode-selection');
  bool _wasActive = false;

  @override
  void initState() {
    super.initState();
    widget.selection.addListener(_changed);
  }

  @override
  void dispose() {
    widget.selection.removeListener(_changed);
    _focus.dispose();
    super.dispose();
  }

  void _changed() {
    final active = widget.selection.active;
    // Escape only reaches a focused subtree; take focus on entering so a
    // keyboard user can leave the way they would anywhere else.
    if (active && !_wasActive) _focus.requestFocus();
    _wasActive = active;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.selection.active;
    return PopScope(
      canPop: !active,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) widget.selection.exit();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (widget.selection.active) widget.selection.exit();
          },
        },
        child: Focus(focusNode: _focus, child: widget.child),
      ),
    );
  }
}
