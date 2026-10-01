import 'dart:io';

import 'package:comms_core/comms_core.dart' show feedUnreachableReason;
import 'package:flutter/material.dart';
import 'package:openhearth_design/openhearth_design.dart';

import '../../db/database.dart';
import '../dsp/dsp_coordinator.dart';
import '../episodes/episode_actions.dart';
import '../transcribe/transcribe_coordinator.dart';
import '../works/work_menu.dart';
import '../works/work_open.dart';
import '../works/work_row.dart';
import '../episodes/episode_selection.dart';
import '../player/player_controller.dart';
import '../reader/reader_doors.dart';
import 'episode_download_coordinator.dart';
import 'feed_ingest.dart';
import 'feed_settings_screen.dart';
import 'feeds_repository.dart';
import '../shared/capped_body.dart';

/// The podcast page (ADR-0016 section 2): one show's episodes, by date in
/// the direction the listener chose, as a place to listen from. Rows play,
/// download and queue; "Play from here" and "Add unplayed to Queue" are
/// the listener's own acts, so the queue still only holds what they put
/// there (ADR-0003 law 1 forbids ranking, not a second date-ordered list).
///
/// A failing feed says why at the top, with a way to try again, and the
/// RFC 5005 "Fetch older episodes" action sits at the foot when the feed
/// offers an archive.
class FeedDetailScreen extends StatefulWidget {
  final AppDatabase db;
  final FeedsRepository repository;
  final Feed feed;

  /// Null where nothing can play (tests of the archive footer, say); the
  /// play buttons are then not offered.
  final PlayerController? playerController;
  final EpisodeDownloadCoordinator? downloadCoordinator;
  final DspCoordinator? dspCoordinator;
  final bool localMlAvailable;

  /// The reader's kit (voice, dictionary, translation), the same one
  /// Latest opens a transcript with. Null, or a kit with no player, falls
  /// back to a bare kit around [playerController].
  final ReaderDoors? readerDoors;

  /// Runs the shared Transcribe and Translate; null where this tier
  /// can't, which hides them here as everywhere else.
  final TranscribeCoordinator? transcriber;

  const FeedDetailScreen(
      {super.key,
      required this.db,
      required this.repository,
      required this.feed,
      this.playerController,
      this.downloadCoordinator,
      this.dspCoordinator,
      this.localMlAvailable = true,
      this.readerDoors,
      this.transcriber});

  @override
  State<FeedDetailScreen> createState() => _FeedDetailScreenState();
}

class _FeedDetailScreenState extends State<FeedDetailScreen> {
  late Feed _feed;
  List<EpisodeEntry>? _episodes;
  WorkListState _rowState = WorkListState.empty;
  bool _fetching = false;
  bool _retrying = false;

  late final EpisodeActions _actions = EpisodeActions(
    db: widget.db,
    profileId: widget.feed.profileId,
    player: widget.playerController,
    downloader: widget.downloadCoordinator,
    dsp: widget.dspCoordinator,
    services: widget.repository.services,
    localMlAvailable: widget.localMlAvailable,
    transcriber: widget.transcriber,
    // This show is the page beneath: "From …" goes back to it.
    openShow: (context, feed) async => Navigator.of(context).pop(),
  );

  final _selection = EpisodeSelection();
  final _undo = OhUndoController();
  late final EpisodeBulk _bulk =
      EpisodeBulk(actions: _actions, selection: _selection, undo: _undo);

  @override
  void initState() {
    super.initState();
    _feed = widget.feed;
    _selection.reload = _load;
    _selection.addListener(_onSelection);
    _load();
  }

  @override
  void dispose() {
    _selection.removeListener(_onSelection);
    _selection.dispose();
    _undo.dispose();
    super.dispose();
  }

  void _onSelection() => setState(() {});

  /// Older means published earlier in this feed, whichever way the page
  /// is sorted; ties are neither older nor newer.
  List<EpisodeEntry> _olderUnplayed(EpisodeEntry e) => unplayedAudio([
        for (final o in _episodes ?? const <EpisodeEntry>[])
          if (o.episode.publishedAtMs < e.episode.publishedAtMs) o,
      ]);

  /// The show's artwork, if it is on disk; checked in [_load].
  File? _art;

  Future<void> _load() async {
    final episodes = await widget.db.feedsDao
        .episodesOfFeed(_feed.id, oldestFirst: _feed.sortOldestFirst);
    final rowState = await WorkListState.load(widget.db, _feed.profileId,
        entries: episodes);
    if (!mounted) return;
    // Disk checks happen here, once per load, never per frame.
    _actions.forgetArtwork();
    final art = widget.localMlAvailable
        ? widget.repository.services?.artworkFileFor(_feed.id)
        : null;
    _selection.universe = episodes;
    setState(() {
      _episodes = episodes;
      _rowState = rowState;
      _art = art != null && art.existsSync() ? art : null;
    });
  }

  Future<void> _setOldestFirst(bool oldestFirst) async {
    if (oldestFirst == _feed.sortOldestFirst) return;
    await widget.db.feedsDao.setSortOldestFirst(_feed.id, oldestFirst);
    setState(() => _feed = _feed.copyWith(sortOldestFirst: oldestFirst));
    await _load();
  }

  Future<void> _fetchOlder() async {
    setState(() => _fetching = true);
    final outcome = await widget.repository.fetchOlderEpisodes(_feed);
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    setState(() => _fetching = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(outcome.message)));
  }

  Future<void> _retry() async {
    setState(() => _retrying = true);
    await widget.repository.refreshFeed(_feed, force: true);
    final fresh = await widget.db.feedsDao.feedById(_feed.id);
    if (!mounted) return;
    setState(() {
      if (fresh != null) _feed = fresh;
      _retrying = false;
    });
    await _load();
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => FeedSettingsScreen(
            db: widget.db,
            feed: _feed,
            offerAutoDownload: widget.repository.offersAutoDownload)));
    final fresh = await widget.db.feedsDao.feedById(_feed.id);
    if (fresh != null && mounted) setState(() => _feed = fresh);
  }

  Future<void> _addUnplayed() async {
    final added = await _actions.addUnplayed(_episodes ?? const []);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        persist: false,
        content: Text(switch (added) {
          0 => 'Everything here is already played or in the Queue.',
          1 => 'Added 1 episode to the Queue.',
          _ => 'Added $added episodes to the Queue.',
        }),
      ));
  }

  WorkDoors get _workDoors => WorkDoors(
      db: widget.db,
      profileId: _feed.profileId,
      readerDoors:
          widget.readerDoors ?? ReaderDoors(player: widget.playerController),
      actions: _actions);

  Future<void> _open(EpisodeEntry e) async {
    final removal = await _workDoors.open(context, e, showTitle: _feed.title);
    await _load();
    // Removed from its page: show the list as it is once the Undo goes.
    removal?.then((_) => mounted ? _load() : null);
  }

  Future<void> _onMenu(String choice, int index) async {
    final e = _episodes![index];
    if (choice == 'play-from-here') {
      await _actions.playFromHere(_episodes!, index);
    } else if (choice == 'mark-older') {
      await _bulk.markOlderPlayed(context, _olderUnplayed(e));
      return;
    } else {
      await _actions.handleShared(context, choice, e,
          showTitle: _feed.title);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final episodes = _episodes;
    return Scaffold(
      bottomSheet: OhUndoBar(controller: _undo),
      appBar: _selection.active
          ? _bulk.bar(context)
          : AppBar(
              title: Text(_feed.title.isEmpty ? _feed.url : _feed.title,
                  overflow: TextOverflow.ellipsis),
              actions: [
                if (episodes?.isNotEmpty ?? false)
                  OhBarActions(children: [
                    OhBarOverflow<String>(
                      key: const Key('podcast-more'),
                      onSelected: (_) => _selection.enter(),
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          key: Key('podcast-select'),
                          value: 'select',
                          child: Text('Select'),
                        ),
                      ],
                    ),
                  ]),
              ],
            ),
      body: CappedBody(child: _bulk.scope(child: switch (episodes) {
        null => const Center(child: CircularProgressIndicator()),
        // Built as rows scroll in: a back catalogue of 2,000 episodes
        // used to build 2,000 rows (and check their artwork on disk)
        // before the first frame.
        _ => _list(episodes),
      })),
    );
  }

  Widget _list(List<EpisodeEntry> episodes) {
    final problem = _problem();
    final lead = problem == null ? 1 : 2;
    return ListView.builder(
      itemCount: lead + episodes.length + 1,
      itemBuilder: (_, i) {
        if (problem != null && i == 0) return problem;
        if (i == lead - 1) return _header(episodes);
        if (i == lead + episodes.length) return _footer();
        return _row(episodes, i - lead);
      },
    );
  }

  Widget _header(List<EpisodeEntry> episodes) {
    final theme = Theme.of(context);
    final unplayed = episodes
        .where((e) =>
            e.episode.enclosureUrl != null && e.episode.finishedAtMs == null)
        .length;
    final art = _art;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (art != null)
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.file(art,
                        width: 72,
                        height: 72,
                        cacheWidth: thumbCacheWidth(context, 72),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const SizedBox.shrink()),
                  ),
                ),
              Expanded(
                child: Text(
                  episodes.length == 1
                      ? '1 episode · $unplayed unplayed'
                      : '${episodes.length} episodes · $unplayed unplayed',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (unplayed > 0)
                FilledButton.tonalIcon(
                  key: const Key('add-unplayed'),
                  onPressed: _addUnplayed,
                  icon: const Icon(Icons.playlist_add),
                  label: const Text('Add unplayed to Queue'),
                ),
              OutlinedButton.icon(
                key: const Key('podcast-settings'),
                onPressed: _openSettings,
                icon: const Icon(Icons.tune),
                label: const Text('Podcast settings'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ChoiceChip(
                key: const Key('sort-newest'),
                label: const Text('Newest first'),
                selected: !_feed.sortOldestFirst,
                onSelected: (_) => _setOldestFirst(false),
              ),
              ChoiceChip(
                key: const Key('sort-oldest'),
                label: const Text('Oldest first'),
                selected: _feed.sortOldestFirst,
                onSelected: (_) => _setOldestFirst(true),
              ),
            ],
          ),
        ],
      ),
    );
  }

  ReaderDoors get _transcriptDoors {
    final doors = widget.readerDoors;
    return doors != null && doors.canOpenTranscript
        ? doors
        : ReaderDoors(player: widget.playerController);
  }

  Widget _row(List<EpisodeEntry> episodes, int i) {
    final e = episodes[i];
    final isAudio = e.episode.enclosureUrl != null;
    final canPlay = isAudio && widget.playerController != null;
    final selecting = _selection.active;
    return WorkRow(
      work: e.work,
      episode: e.episode,
      facts: WorkRowFacts.of(e.work, e.episode, _rowState,
          downloaded: isAudio && _actions.isDownloaded(e.episode)),
      artwork: _actions.artworkFor(e.episode),
      onTap: selecting ? () => _selection.toggle(e.work.id) : () => _open(e),
      selected: selecting ? _selection.contains(e.work.id) : null,
      onLongPress: selecting
          ? () => _selection.toggle(e.work.id)
          : () => _selection.enter(e.work.id),
      onPlay: canPlay
          ? () async {
              await _actions.play(e.work);
              await _load();
            }
          : null,
      onRead: canPlay || !isAudio
          ? () async {
              await (isAudio
                  ? _transcriptDoors
                      .openTranscript(context, db: widget.db, work: e.work)
                  : _workDoors.readFromRow(context, e));
              await _load();
            }
          : null,
      onMenu: (choice) => _onMenu(choice, i),
      // The shared items first, then this page's own.
      menuBuilder: (_) => workMenuItems(_actions, e,
          transcribed: _rowState.transcribed.contains(e.work.id), extras: [
        if (canPlay)
          PopupMenuItem(
              key: Key('play-from-here-${e.work.id}'),
              value: 'play-from-here',
              child: const Text('Play from here')),
        if (isAudio && _olderUnplayed(e).isNotEmpty)
          PopupMenuItem(
              key: Key('mark-older-${e.work.id}'),
              value: 'mark-older',
              child: const Text('Mark everything older as played')),
      ]),
    );
  }

  Widget? _problem() {
    final state = stateOfFeed(_feed);
    if (state.consecutiveFailures == 0 && !state.broken) return null;
    final error = Theme.of(context).colorScheme.error;
    return ListTile(
      key: const Key('feed-problem'),
      leading: Icon(Icons.error_outline, color: error),
      title: Text(state.lastError ?? feedUnreachableReason),
      // A broken feed is checked only once a week (ADR-0017), so the
      // listener must hear that it won't fix itself soon.
      subtitle: state.broken
          ? const Text('Trellis now checks this feed only once a week.')
          : null,
      trailing: TextButton(
        onPressed: _retrying ? null : _retry,
        child: const Text('Try again'),
      ),
    );
  }

  Widget _footer() {
    if (_feed.nextPageUrl != null) {
      return ListTile(
        key: const Key('fetch-older-episodes'),
        leading: _fetching
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.history),
        title: const Text('Fetch older episodes'),
        onTap: _fetching ? null : _fetchOlder,
      );
    }
    return Padding(
      key: const Key('no-archive-note'),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Text(noFeedArchiveNote,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall),
    );
  }
}
