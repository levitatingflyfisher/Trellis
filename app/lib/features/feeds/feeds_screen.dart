import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:comms_core/comms_core.dart' as comms;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:openhearth_design/openhearth_design.dart';

import '../../db/database.dart';
import '../../services/picked_save.dart';
import '../dsp/dsp_coordinator.dart';
import '../player/player_controller.dart';
import '../episodes/episode_actions.dart';
import '../episodes/episode_row.dart' show thumbCacheWidth;
import '../reader/reader_doors.dart';
import '../search/search_entry.dart';
import '../search/search_screen.dart';
import 'episode_download_coordinator.dart';
import 'feed_detail_screen.dart';
import 'feed_ingest.dart';
import 'feed_settings_screen.dart';
import 'feeds_repository.dart';
import 'subscribe_screen.dart';
import '../shared/capped_body.dart';

/// The platform seams for OPML files — injectable so widget tests never
/// touch a platform channel. Pure parsing/serialization is comms_core's.
typedef OpmlBytesPicker = Future<List<int>?> Function();
typedef OpmlBytesSaver =
    Future<bool> Function(String suggestedName, List<int> bytes);

Future<List<int>?> pickOpmlWithFilePicker() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['opml', 'xml'],
    withData: true,
  );
  final file = result?.files.firstOrNull;
  if (file == null) return null;
  return file.bytes ?? await File(file.path!).readAsBytes();
}

Future<bool> saveOpmlWithFilePicker(
  String suggestedName,
  List<int> bytes,
) async {
  final path = await FilePicker.platform.saveFile(
    fileName: suggestedName,
    bytes: Uint8List.fromList(bytes),
  );
  return finishPickedSave(path, bytes);
}

/// Subscriptions (ADR-0016 section 3): every source, shelved by where it
/// came from (Podcasts, Blogs and newsletters, Books), plus follow,
/// unfollow (cascading unpromoted ephemera — ADR-0003 law 2) and OPML both
/// ways. Shelves are alphabetical, never ranked (ADR-0003 law 1).
class FeedsScreen extends StatefulWidget {
  final AppDatabase db;
  final FeedsRepository repository;
  final Profile profile;
  final OpmlBytesPicker pickOpmlBytes;
  final OpmlBytesSaver saveOpmlBytes;

  /// DeviceServices.localMlAvailable, handed down by the shell. Where
  /// false (the web tier) the household DSP default toggle is simply not
  /// offered — it would set a preference nothing on this tier can ever
  /// act on (dart:io's File throws on any real op under dart2js).
  final bool localMlAvailable;

  /// Handed on to each podcast page so it can play, download and process
  /// from its rows; null leaves those doors closed.
  final PlayerController? playerController;
  final EpisodeDownloadCoordinator? downloadCoordinator;
  final DspCoordinator? dspCoordinator;

  /// How the Books shelf opens a book: the Library's own way, so voice,
  /// recap and translation behave the same from either door.
  final ReaderDoors readerDoors;

  const FeedsScreen({
    super.key,
    required this.db,
    required this.repository,
    required this.profile,
    this.localMlAvailable = true,
    this.playerController,
    this.downloadCoordinator,
    this.dspCoordinator,
    this.readerDoors = const ReaderDoors(),
    OpmlBytesPicker? pickOpmlBytes,
    OpmlBytesSaver? saveOpmlBytes,
  }) : pickOpmlBytes = pickOpmlBytes ?? pickOpmlWithFilePicker,
       saveOpmlBytes = saveOpmlBytes ?? saveOpmlWithFilePicker;

  @override
  State<FeedsScreen> createState() => _FeedsScreenState();
}

class _FeedsScreenState extends State<FeedsScreen> {
  List<Feed>? _feeds;
  Map<int, int> _unplayed = const {};
  List<_Book> _books = const [];
  bool _dspGlobalDefault = false;

  /// Set while an OPML import is checking its new feeds.
  ({int done, int total})? _importProgress;
  bool _importing = false;

  /// Feeds unfollowed but still on offer to Undo (fleet delete ruling:
  /// a deliberate unfollow doesn't ask; its Undo never times out). The
  /// cascade runs only when the offer is let go.
  final Set<int> _unfollowing = {};
  final OhUndoController _undo = OhUndoController();

  @override
  void dispose() {
    _undo.dispose();
    super.dispose();
  }

  /// Leaving lets a pending unfollow go, and the cascade finishes before the
  /// route pops: the Inbox reloads as soon as it is back and must not show
  /// the unfollowed feed's items.
  Future<void> _leave() async {
    await _undo.dismiss();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Each followed show's artwork that is on disk, by feed id.
  Map<int, File> _art = const {};

  Future<void> _load() async {
    final profileId = widget.profile.id;
    final feeds = await widget.db.feedsDao.feedsOf(profileId);
    final unplayed = await widget.db.feedsDao.unplayedCountsOf(profileId);
    final books = await widget.db.spineDao.booksOf(profileId);
    final dspGlobalDefault = await widget.db.profilesDao.dspGlobalDefault(
      profileId,
    );
    if (!mounted) return;
    // Disk checks happen here, once per load, never per frame.
    final services = widget.localMlAvailable ? widget.repository.services : null;
    final art = <int, File>{
      if (services != null)
        for (final f in feeds)
          if (services.artworkFileFor(f.id) case final file
              when file.existsSync())
            f.id: file,
    };
    setState(() {
      _art = art;
      _feeds = feeds..sort((a, b) => shelfKey(_feedName(a))
          .compareTo(shelfKey(_feedName(b))));
      _unplayed = unplayed;
      _books = books..sort((a, b) => shelfKey(a.work.title)
          .compareTo(shelfKey(b.work.title)));
      _dspGlobalDefault = dspGlobalDefault;
    });
  }

  Future<void> _toggleDspGlobalDefault() async {
    final next = !_dspGlobalDefault;
    await widget.db.profilesDao.setDspGlobalDefault(widget.profile.id, next);
    if (!mounted) return;
    setState(() => _dspGlobalDefault = next);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _follow() async {
    final followed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SubscribeScreen(
          repository: widget.repository,
          profileId: widget.profile.id,
        ),
      ),
    );
    if (followed == true) await _load();
  }

  void _unfollow(Feed feed) {
    final name = feed.title.isEmpty ? feed.url : feed.title;
    setState(() => _unfollowing.add(feed.id));
    _undo.show(
      message: "Unfollowed '$name'. Its unread items go too; anything you "
          'kept stays in the library.',
      onUndo: () async {
        if (mounted) setState(() => _unfollowing.remove(feed.id));
      },
      onCommit: () async {
        await widget.db.feedsDao.deleteFeedCascade(feed.id);
        _unfollowing.remove(feed.id);
        if (mounted) await _load();
      },
    );
  }

  Future<void> _openSettings(Feed feed) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => FeedSettingsScreen(db: widget.db, feed: feed),
      ),
    );
    await _load();
  }

  Future<void> _importOpml() async {
    // One import at a time: a second would race the first's progress.
    if (_importing) return;
    _importing = true;
    try {
      await _importOpmlUnguarded();
    } finally {
      _importing = false;
    }
  }

  Future<void> _importOpmlUnguarded() async {
    final bytes = await widget.pickOpmlBytes();
    if (bytes == null) return;
    final List<comms.OpmlOutline> outlines;
    try {
      outlines = comms.parseOpml(utf8.decode(bytes, allowMalformed: true));
    } on comms.OpmlParseException catch (e) {
      // The parser's words ("Invalid OPML file") are for the log.
      debugPrint('OPML import refused: ${e.message}');
      _toast("That file isn’t an OPML podcast list Trellis can read.");
      return;
    }
    if (outlines.isEmpty) {
      _toast('No feed URLs found in that file.');
      return;
    }
    final added = await widget.repository.followOutlines(
      widget.profile.id,
      outlines,
    );
    if (added.isEmpty) {
      _toast('Already following all of those.');
      return;
    }
    await _load();
    if (mounted) {
      setState(() => _importProgress = (done: 0, total: added.length));
    }
    // The donor validated each import by fetching; the breaker records the
    // ones that fail, so their rows can say why.
    await widget.repository.refreshMany(
      added,
      onProgress: (done, total) {
        if (!mounted) return;
        setState(() => _importProgress = (done: done, total: total));
        _load();
      },
    );
    final wanted = {for (final f in added) f.id};
    final failed = (await widget.db.feedsDao.feedsOf(widget.profile.id))
        .where((f) => wanted.contains(f.id))
        .map(stateOfFeed)
        .where((s) => s.consecutiveFailures > 0 || s.broken)
        .length;
    if (mounted) setState(() => _importProgress = null);
    await _load();
    final n = added.length;
    final followed = 'Following $n new ${n == 1 ? 'feed' : 'feeds'}.';
    _toast(switch (failed) {
      0 => followed,
      1 => '$followed 1 couldn’t be reached; its row says why.',
      _ => '$followed $failed couldn’t be reached; their rows say why.',
    });
  }

  Future<void> _exportOpml() async {
    final feeds = await widget.db.feedsDao.feedsOf(widget.profile.id);
    if (feeds.isEmpty) {
      _toast('Nothing to export yet.');
      return;
    }
    final xml = comms.exportOpml([
      for (final f in feeds) comms.OpmlOutline(url: f.url, title: f.title),
    ], profileName: widget.profile.name);
    final saved = await widget.saveOpmlBytes(
      'trellis-feeds.opml',
      utf8.encode(xml),
    );
    if (saved) _toast('Exported ${feeds.length} feeds.');
  }

  @override
  Widget build(BuildContext context) {
    final feeds = _feeds == null
        ? null
        : [
            for (final f in _feeds!)
              if (!_unfollowing.contains(f.id)) f
          ];
    final empty = feeds != null && feeds.isEmpty && _books.isEmpty;
    return PopScope(
      canPop: _unfollowing.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        bottomSheet: OhUndoBar(controller: _undo),
        appBar: AppBar(
          title: const Text('Subscriptions'),
          actions: [
            OhBarActions(children: [
            OhBarOverflow<String>(
              key: const Key('opml-menu'),
              onSelected: (v) => switch (v) {
                'import' => _importOpml(),
                'export' => _exportOpml(),
                _ => _toggleDspGlobalDefault(),
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'import', child: Text('Import OPML')),
                const PopupMenuItem(value: 'export', child: Text('Export OPML')),
                if (widget.localMlAvailable)
                  CheckedPopupMenuItem<String>(
                    key: const Key('dsp-global-default-toggle'),
                    value: 'dsp-default',
                    checked: _dspGlobalDefault,
                    child: const Text(
                      'Trim silence & even out volume by default',
                    ),
                  ),
              ],
            ),
            ]),
          ],
        ),
        // The empty state carries its own Follow; everywhere else this
        // stays in reach, since following is why most people come here.
        floatingActionButton: (feeds == null || empty)
            ? null
            : FloatingActionButton.extended(
                key: const Key('follow'),
                onPressed: _follow,
                icon: const Icon(Icons.add),
                label: const Text('Follow'),
              ),
        body: CappedBody(child: Column(children: [
          if (feeds != null && !empty)
            SearchEntry(
                key: const Key('feeds-search'), onPressed: _openSearch),
          if (_importProgress case final p?) _ImportProgress(progress: p),
          Expanded(child: switch (feeds) {
            null => const Center(child: CircularProgressIndicator()),
            _ when empty => _EmptyFeeds(onFollow: _follow),
            _ => _shelfList(feeds),
          }),
        ])),
      ),
    );
  }

  /// Rows are built as they scroll in: 300 follows used to build 300
  /// tiles before the first frame.
  Widget _shelfList(List<Feed> feeds) {
    final rows = _shelves(feeds);
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: rows.length,
      itemBuilder: (_, i) => rows[i](),
    );
  }

  /// Empty shelves are left out rather than shown with a zero: there is
  /// nothing to see there.
  List<Widget Function()> _shelves(List<Feed> feeds) {
    final podcasts = [for (final f in feeds) if (f.origin != 'blog') f];
    final blogs = [for (final f in feeds) if (f.origin == 'blog') f];
    return [
      if (podcasts.isNotEmpty) ...[
        () => _ShelfHeader(
            key: const Key('shelf-podcasts'),
            title: 'Podcasts',
            count: podcasts.length),
        for (final f in podcasts) () => _feedTile(f),
      ],
      if (blogs.isNotEmpty) ...[
        () => _ShelfHeader(
            key: const Key('shelf-blogs'),
            title: 'Blogs and newsletters',
            count: blogs.length),
        for (final f in blogs) () => _feedTile(f),
      ],
      if (_books.isNotEmpty) ...[
        () => _ShelfHeader(
            key: const Key('shelf-books'),
            title: 'Books',
            count: _books.length),
        for (final b in _books) () => _bookTile(b),
      ],
    ];
  }

  Future<void> _openSearch() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => SearchScreen(
            doors: SearchDoors(
                db: widget.db,
                profile: widget.profile,
                actions: EpisodeActions(
                    db: widget.db,
                    profileId: widget.profile.id,
                    player: widget.playerController,
                    downloader: widget.downloadCoordinator,
                    dsp: widget.dspCoordinator,
                    services: widget.repository.services,
                    localMlAvailable: widget.localMlAvailable),
                readerDoors: widget.readerDoors))));
    await _load();
  }

  Future<void> _openBook(_Book b) async {
    await widget.readerDoors.open(context,
        db: widget.db,
        profileId: widget.profile.id,
        work: b.work,
        position: b.position,
        segmentCount: b.segmentCount);
    await _load(); // progress may have moved
  }

  Widget _bookTile(_Book b) {
    final small = Theme.of(context).textTheme.bodySmall;
    final progress = _bookProgress(b);
    return ListTile(
      key: Key('book-${b.work.id}'),
      onTap: () => _openBook(b),
      leading: const _Thumb(child: Icon(Icons.menu_book_outlined)),
      title: Text(b.work.title, overflow: TextOverflow.ellipsis, maxLines: 2),
      subtitle: progress == null
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                      progress >= 1
                          ? 'Finished'
                          : '${(progress * 100).round()}% read',
                      style: small),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: LinearProgressIndicator(
                      value: progress,
                      borderRadius: BorderRadius.circular(2)),
                ),
              ],
            ),
    );
  }

  /// Null when nothing is known yet: an unopened book shows no bar rather
  /// than a misleading empty one.
  double? _bookProgress(_Book b) {
    if (b.work.finishedEpochDay != null) return 1;
    final position = b.position;
    if (position == null || b.segmentCount == 0) return null;
    return (position.segmentIdx / b.segmentCount).clamp(0.0, 1.0);
  }

  Future<void> _openFeed(Feed feed) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => FeedDetailScreen(
          db: widget.db,
          repository: widget.repository,
          feed: feed,
          playerController: widget.playerController,
          downloadCoordinator: widget.downloadCoordinator,
          dspCoordinator: widget.dspCoordinator,
          localMlAvailable: widget.localMlAvailable,
        ),
      ),
    );
    await _load();
  }

  /// The unplayed count, and the reason when the feed is failing: that is
  /// what the listener needs to see while scanning the list. Null when
  /// there is neither, so a caught-up healthy row stays one line.
  Widget? _feedSubtitle(Feed feed) {
    final small = Theme.of(context).textTheme.bodySmall;
    final state = stateOfFeed(feed);
    final unplayed = _unplayed[feed.id] ?? 0;
    final failing = state.consecutiveFailures > 0 || state.broken;
    if (unplayed == 0 && !failing) return null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (unplayed > 0)
          Text('$unplayed unplayed',
              key: Key('unplayed-${feed.id}'), style: small),
        if (failing)
          Text(state.lastError ?? comms.feedUnreachableReason,
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
              style: small?.copyWith(
                  color: Theme.of(context).colorScheme.error)),
      ],
    );
  }

  Widget _feedTile(Feed feed) {
    final name = _feedName(feed);
    final art = _art[feed.id];
    final initial = _Initial(name);
    return ListTile(
      onTap: () => _openFeed(feed),
      leading: _Thumb(
        child: art != null
            ? Image.file(art,
                width: 48,
                height: 48,
                cacheWidth: thumbCacheWidth(context, 48),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => initial)
            : initial,
      ),
      title: Text(name, overflow: TextOverflow.ellipsis, maxLines: 2),
      subtitle: _feedSubtitle(feed),
      trailing: PopupMenuButton<String>(
        key: Key('feed-menu-${feed.id}'),
        tooltip: 'More',
        onSelected: (v) =>
            v == 'settings' ? _openSettings(feed) : _unfollow(feed),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'settings', child: Text('Podcast settings')),
          PopupMenuItem(value: 'unfollow', child: Text('Unfollow')),
        ],
      ),
    );
  }
}

typedef _Book = ({Work work, int segmentCount, Position? position});

String _feedName(Feed feed) => feed.title.isEmpty ? feed.url : feed.title;

/// How a shelf sorts a name: by its letters, not its case, and without a
/// leading "The ", so "The Night Sky Cast" files under N as people look
/// for it.
@visibleForTesting
String shelfKey(String name) {
  final lower = name.trim().toLowerCase();
  return lower.startsWith('the ') ? lower.substring(4).trimLeft() : lower;
}

class _ShelfHeader extends StatelessWidget {
  const _ShelfHeader({super.key, required this.title, required this.count});
  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text.rich(
          TextSpan(children: [
            TextSpan(text: title, style: theme.textTheme.titleMedium),
            TextSpan(
                text: '  $count',
                style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }
}

/// A row's square picture. Fixed size so long titles at large text wrap
/// beside it instead of pushing it around.
class _Thumb extends StatelessWidget {
  const _Thumb({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox.square(
          dimension: 48,
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Center(child: child),
          ),
        ),
      );
}

/// The show's first letter, for a feed with no artwork (or none yet).
class _Initial extends StatelessWidget {
  const _Initial(this.name);
  final String name;

  @override
  Widget build(BuildContext context) {
    final trimmed = shelfKey(name);
    final letter = trimmed.isEmpty ? '?' : trimmed.characters.first;
    return Center(
      child: Text(letter.toUpperCase(),
          // The box is fixed, so the letter must not grow with text scale.
          textScaler: TextScaler.noScaling,
          style: Theme.of(context).textTheme.titleLarge),
    );
  }
}

class _EmptyFeeds extends StatelessWidget {
  final VoidCallback onFollow;
  const _EmptyFeeds({required this.onFollow});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                Icons.rss_feed,
                size: 56,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                'No feeds yet.',
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: onFollow,
                icon: const Icon(Icons.add),
                label: const Text('Follow a feed'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Checking 37 of 118…" over a bar, so a long import visibly moves.
class _ImportProgress extends StatelessWidget {
  const _ImportProgress({required this.progress});
  final ({int done, int total}) progress;

  @override
  Widget build(BuildContext context) {
    final (:done, :total) = progress;
    // Counts the feed being worked on, so it never reads "Checking 0".
    final current = done < total ? done + 1 : total;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Checking $current of $total…',
            key: const Key('opml-import-progress'),
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: done / total),
        ],
      ),
    );
  }
}
