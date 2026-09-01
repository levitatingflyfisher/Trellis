import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:comms_core/comms_core.dart' as comms;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:openhearth_design/openhearth_design.dart';

import '../../db/database.dart';
import '../../services/picked_save.dart';
import 'feed_detail_screen.dart';
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

/// Manage subscriptions: follow, unfollow (cascading unpromoted ephemera —
/// ADR-0003 law 2), OPML both ways.
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

  const FeedsScreen({
    super.key,
    required this.db,
    required this.repository,
    required this.profile,
    this.localMlAvailable = true,
    OpmlBytesPicker? pickOpmlBytes,
    OpmlBytesSaver? saveOpmlBytes,
  }) : pickOpmlBytes = pickOpmlBytes ?? pickOpmlWithFilePicker,
       saveOpmlBytes = saveOpmlBytes ?? saveOpmlWithFilePicker;

  @override
  State<FeedsScreen> createState() => _FeedsScreenState();
}

class _FeedsScreenState extends State<FeedsScreen> {
  List<Feed>? _feeds;
  bool _dspGlobalDefault = false;

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

  Future<void> _load() async {
    final feeds = await widget.db.feedsDao.feedsOf(widget.profile.id);
    final dspGlobalDefault = await widget.db.profilesDao.dspGlobalDefault(
      widget.profile.id,
    );
    if (!mounted) return;
    setState(() {
      _feeds = feeds;
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
    var added = 0;
    for (final o in outlines) {
      final existing = await widget.db.feedsDao.feedByUrl(
        widget.profile.id,
        o.url,
      );
      if (existing != null) continue;
      final id = await widget.db.feedsDao.insertFeed(
        profileId: widget.profile.id,
        url: o.url,
        title: o.title,
      );
      added++;
      // The donor validated each import by fetching; the breaker records
      // the ones that fail.
      final feed = (await widget.db.feedsDao.feedsOf(
        widget.profile.id,
      )).firstWhere((f) => f.id == id);
      await widget.repository.refreshFeed(feed);
    }
    await _load();
    _toast(
      added == 0
          ? 'Already following all of those.'
          : 'Following $added new ${added == 1 ? 'feed' : 'feeds'}.',
    );
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
    return PopScope(
      canPop: _unfollowing.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        bottomSheet: OhUndoBar(controller: _undo),
        appBar: AppBar(
          title: const Text('Feeds'),
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
        floatingActionButton: (feeds == null || feeds.isEmpty)
            ? null
            : FloatingActionButton.extended(
                onPressed: _follow,
                icon: const Icon(Icons.add),
                label: const Text('Follow'),
              ),
        body: CappedBody(child: switch (feeds) {
          null => const Center(child: CircularProgressIndicator()),
          [] => _EmptyFeeds(onFollow: _follow),
          _ => ListView.builder(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: feeds.length,
            itemBuilder: (_, i) => _feedTile(feeds[i]),
          ),
        }),
      ),
    );
  }

  Future<void> _openFeed(Feed feed) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => FeedDetailScreen(
          db: widget.db,
          repository: widget.repository,
          feed: feed,
        ),
      ),
    );
    await _load();
  }

  Widget _feedTile(Feed feed) {
    return ListTile(
      onTap: () => _openFeed(feed),
      leading: const Icon(Icons.rss_feed),
      title: Text(
        feed.title.isEmpty ? feed.url : feed.title,
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      ),
      subtitle: Text(
        feed.url,
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
        style: Theme.of(context).textTheme.bodySmall,
      ),
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
