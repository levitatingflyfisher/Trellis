import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:comms_core/comms_core.dart' as comms;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../../services/picked_save.dart';
import 'feeds_repository.dart';
import 'subscribe_screen.dart';

/// The platform seams for OPML files — injectable so widget tests never
/// touch a platform channel. Pure parsing/serialization is comms_core's.
typedef OpmlBytesPicker = Future<List<int>?> Function();
typedef OpmlBytesSaver = Future<bool> Function(
    String suggestedName, List<int> bytes);

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
    String suggestedName, List<int> bytes) async {
  final path = await FilePicker.platform.saveFile(
      fileName: suggestedName, bytes: Uint8List.fromList(bytes));
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
  const FeedsScreen(
      {super.key,
      required this.db,
      required this.repository,
      required this.profile,
      OpmlBytesPicker? pickOpmlBytes,
      OpmlBytesSaver? saveOpmlBytes})
      : pickOpmlBytes = pickOpmlBytes ?? pickOpmlWithFilePicker,
        saveOpmlBytes = saveOpmlBytes ?? saveOpmlWithFilePicker;

  @override
  State<FeedsScreen> createState() => _FeedsScreenState();
}

class _FeedsScreenState extends State<FeedsScreen> {
  List<Feed>? _feeds;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final feeds = await widget.db.feedsDao.feedsOf(widget.profile.id);
    if (!mounted) return;
    setState(() => _feeds = feeds);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _follow() async {
    final followed = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => SubscribeScreen(
            repository: widget.repository, profileId: widget.profile.id)));
    if (followed == true) await _load();
  }

  Future<void> _unfollow(Feed feed) async {
    final name = feed.title.isEmpty ? feed.url : feed.title;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text("Unfollow '$name'?"),
        content: const Text(
            'Its unread river items go too. Anything you pinned or '
            'finished stays in the library.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Keep following')),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Unfollow')),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.db.feedsDao.deleteFeedCascade(feed.id);
    await _load();
  }

  Future<void> _importOpml() async {
    final bytes = await widget.pickOpmlBytes();
    if (bytes == null) return;
    final List<comms.OpmlOutline> outlines;
    try {
      outlines = comms.parseOpml(utf8.decode(bytes, allowMalformed: true));
    } on comms.OpmlParseException catch (e) {
      _toast(e.message);
      return;
    }
    if (outlines.isEmpty) {
      _toast('No feed URLs found in that file.');
      return;
    }
    var added = 0;
    for (final o in outlines) {
      final existing =
          await widget.db.feedsDao.feedByUrl(widget.profile.id, o.url);
      if (existing != null) continue;
      final id = await widget.db.feedsDao.insertFeed(
          profileId: widget.profile.id, url: o.url, title: o.title);
      added++;
      // The donor validated each import by fetching; the breaker records
      // the ones that fail.
      final feed = (await widget.db.feedsDao.feedsOf(widget.profile.id))
          .firstWhere((f) => f.id == id);
      await widget.repository.refreshFeed(feed);
    }
    await _load();
    _toast(added == 0
        ? 'Already following all of those.'
        : 'Following $added new ${added == 1 ? 'feed' : 'feeds'}.');
  }

  Future<void> _exportOpml() async {
    final feeds = await widget.db.feedsDao.feedsOf(widget.profile.id);
    if (feeds.isEmpty) {
      _toast('Nothing to export yet.');
      return;
    }
    final xml = comms.exportOpml(
        [for (final f in feeds) comms.OpmlOutline(url: f.url, title: f.title)],
        profileName: widget.profile.name);
    final saved =
        await widget.saveOpmlBytes('trellis-feeds.opml', utf8.encode(xml));
    if (saved) _toast('Exported ${feeds.length} feeds.');
  }

  @override
  Widget build(BuildContext context) {
    final feeds = _feeds;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Feeds'),
        actions: [
          PopupMenuButton<String>(
            key: const Key('opml-menu'),
            onSelected: (v) =>
                v == 'import' ? _importOpml() : _exportOpml(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'import', child: Text('Import OPML')),
              PopupMenuItem(value: 'export', child: Text('Export OPML')),
            ],
          ),
        ],
      ),
      floatingActionButton: (feeds == null || feeds.isEmpty)
          ? null
          : FloatingActionButton.extended(
              onPressed: _follow,
              icon: const Icon(Icons.add),
              label: const Text('Follow')),
      body: switch (feeds) {
        null => const Center(child: CircularProgressIndicator()),
        [] => _EmptyFeeds(onFollow: _follow),
        _ => ListView.builder(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: feeds.length,
            itemBuilder: (_, i) => _feedTile(feeds[i]),
          ),
      },
    );
  }

  Widget _feedTile(Feed feed) {
    return ListTile(
      leading: const Icon(Icons.rss_feed),
      title: Text(feed.title.isEmpty ? feed.url : feed.title,
          overflow: TextOverflow.ellipsis, maxLines: 1),
      subtitle: Text(feed.url,
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
          style: Theme.of(context).textTheme.bodySmall),
      trailing: PopupMenuButton<String>(
        key: Key('feed-menu-${feed.id}'),
        onSelected: (_) => _unfollow(feed),
        itemBuilder: (_) => const [
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
              Icon(Icons.rss_feed,
                  size: 56, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text('No feeds yet.',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton.icon(
                  onPressed: onFollow,
                  icon: const Icon(Icons.add),
                  label: const Text('Follow a feed')),
            ],
          ),
        ),
      ),
    );
  }
}
