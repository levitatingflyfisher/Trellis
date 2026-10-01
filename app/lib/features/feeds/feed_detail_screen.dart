import 'package:comms_core/comms_core.dart' show feedUnreachableReason;
import 'package:flutter/material.dart';

import '../../db/database.dart';
import 'feed_ingest.dart';
import 'feeds_repository.dart';
import '../shared/capped_body.dart';

/// One feed's own episodes, newest first — and the RFC 5005 escape hatch:
/// a quiet "Fetch older episodes" action when the last refresh found an
/// archive link, or, for the near-universal case where it didn't, one
/// calm line saying the publisher's feed simply doesn't offer more.
///
/// Deliberately narrow: tiles here show title and date only. Playing,
/// transcribing, and opening the reader stay the River's job (ADR-0003 law
/// 1's one ordering lives there); this screen exists for the archive
/// affordance, not as a second river. A feed that is failing says why at
/// the top, with a way to try again.
class FeedDetailScreen extends StatefulWidget {
  final AppDatabase db;
  final FeedsRepository repository;
  final Feed feed;
  const FeedDetailScreen(
      {super.key,
      required this.db,
      required this.repository,
      required this.feed});

  @override
  State<FeedDetailScreen> createState() => _FeedDetailScreenState();
}

class _FeedDetailScreenState extends State<FeedDetailScreen> {
  late Feed _feed;
  List<({Work work, Episode episode})>? _episodes;
  bool _fetching = false;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    _feed = widget.feed;
    _load();
  }

  Future<void> _load() async {
    final episodes = await widget.db.feedsDao.episodesOfFeed(_feed.id);
    if (!mounted) return;
    setState(() => _episodes = episodes);
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

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _formatDay(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.day} ${_months[d.month - 1]}';
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
            for (final e in episodes) _episodeTile(e),
            _footer(),
          ]),
      }),
    );
  }

  Widget _episodeTile(({Work work, Episode episode}) e) {
    return ListTile(
      leading: const Icon(Icons.podcasts),
      title: Text(e.work.title, overflow: TextOverflow.ellipsis, maxLines: 2),
      subtitle: Text(_formatDay(e.episode.publishedAtMs)),
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
