import 'package:comms_core/comms_core.dart' show feedUnreachableReason;
import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../dsp/dsp_coordinator.dart';
import '../episodes/episode_actions.dart';
import '../episodes/episode_row.dart';
import '../player/player_controller.dart';
import '../reader/reader_screen.dart';
import 'episode_download_coordinator.dart';
import 'feed_ingest.dart';
import 'feed_settings_screen.dart';
import 'feeds_repository.dart';
import '../shared/capped_body.dart';

/// The podcast page (ADR-0016 section 2): one show's episodes, by date in
/// the direction the listener chose, as a place to listen from. Rows play,
/// download and queue; "Play from here" and "Add unplayed to Up Next" are
/// the listener's own acts, so Up Next still only holds what they put
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

  const FeedDetailScreen(
      {super.key,
      required this.db,
      required this.repository,
      required this.feed,
      this.playerController,
      this.downloadCoordinator,
      this.dspCoordinator,
      this.localMlAvailable = true});

  @override
  State<FeedDetailScreen> createState() => _FeedDetailScreenState();
}

class _FeedDetailScreenState extends State<FeedDetailScreen> {
  late Feed _feed;
  List<EpisodeEntry>? _episodes;
  EpisodeListState _rowState = EpisodeListState.empty;
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
  );

  @override
  void initState() {
    super.initState();
    _feed = widget.feed;
    _load();
  }

  Future<void> _load() async {
    final episodes = await widget.db.feedsDao
        .episodesOfFeed(_feed.id, oldestFirst: _feed.sortOldestFirst);
    final rowState = await EpisodeListState.load(widget.db, _feed.profileId);
    if (!mounted) return;
    setState(() {
      _episodes = episodes;
      _rowState = rowState;
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
        builder: (_) => FeedSettingsScreen(db: widget.db, feed: _feed)));
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
          0 => 'Everything here is already played or in Up Next.',
          1 => 'Added 1 episode to Up Next.',
          _ => 'Added $added episodes to Up Next.',
        }),
      ));
  }

  Future<void> _open(EpisodeEntry e) async {
    await widget.db.feedsDao
        .markRead(e.work.id, DateTime.now().millisecondsSinceEpoch);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ReaderScreen(
            db: widget.db,
            profileId: _feed.profileId,
            work: e.work,
            player: widget.playerController)));
    await _load();
  }

  Future<void> _onMenu(String choice, int index) async {
    final e = _episodes![index];
    if (choice == 'play-from-here') {
      await _actions.playFromHere(_episodes!, index);
    } else {
      await _actions.handleCommon(context, choice, e);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final episodes = _episodes;
    return Scaffold(
      appBar: AppBar(
        title: Text(_feed.title.isEmpty ? _feed.url : _feed.title,
            overflow: TextOverflow.ellipsis),
      ),
      body: CappedBody(child: switch (episodes) {
        null => const Center(child: CircularProgressIndicator()),
        _ => ListView(children: [
            ?_problem(),
            _header(episodes),
            for (var i = 0; i < episodes.length; i++) _row(episodes, i),
            _footer(),
          ]),
      }),
    );
  }

  Widget _header(List<EpisodeEntry> episodes) {
    final theme = Theme.of(context);
    final unplayed = episodes
        .where((e) =>
            e.episode.enclosureUrl != null && e.episode.finishedAtMs == null)
        .length;
    final art = widget.localMlAvailable
        ? widget.repository.services?.artworkFileFor(_feed.id)
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (art != null && art.existsSync())
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.file(art,
                        width: 72,
                        height: 72,
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
                  label: const Text('Add unplayed to Up Next'),
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

  Widget _row(List<EpisodeEntry> episodes, int i) {
    final e = episodes[i];
    final isAudio = e.episode.enclosureUrl != null;
    final canPlay = isAudio && widget.playerController != null;
    return EpisodeRow(
      work: e.work,
      episode: e.episode,
      facts: EpisodeRowFacts.of(e.episode, _rowState,
          downloaded: isAudio && _actions.isDownloaded(e.episode)),
      artwork: _actions.artworkFor(e.episode),
      onTap: () => _open(e),
      onPlay: canPlay
          ? () async {
              await _actions.play(e.work);
              await _load();
            }
          : null,
      onMenu: (choice) => _onMenu(choice, i),
      menuBuilder: (_) => [
        if (canPlay)
          PopupMenuItem(
              key: Key('play-from-here-${e.work.id}'),
              value: 'play-from-here',
              child: const Text('Play from here')),
        ..._actions.commonMenuItems(e),
      ],
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
      // A broken feed is skipped by every refresh, so the listener must hear
      // that nothing will change on its own.
      subtitle: state.broken
          ? const Text('Trellis has stopped checking this feed.')
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
