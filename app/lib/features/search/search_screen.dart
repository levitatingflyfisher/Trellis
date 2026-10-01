/// History and search (ADR-0016 section 4): one box over titles, show
/// names and transcripts, and, before anything is typed, what was played
/// or read, newest first.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:loom_core/loom_core.dart' as core;
import 'package:openhearth_design/openhearth_design.dart';

import '../../db/database.dart' hide Alignment;
import '../episodes/episode_actions.dart';
import '../episodes/episode_row.dart';
import '../episodes/episode_selection.dart';
import '../models/format.dart';
import '../reader/reader_doors.dart';
import '../shared/capped_body.dart';
import 'history_days.dart';
import 'search_store.dart';
import 'share_item.dart';

/// What history and search rows need to act, carried as one value so the
/// Latest and the Subscriptions page open these screens the same way.
class SearchDoors {
  final AppDatabase db;
  final Profile profile;
  final EpisodeActions actions;
  final ReaderDoors readerDoors;
  final ShareText? shareText;

  /// The clock the day headings read; a test pins it.
  final DateTime Function() now;

  SearchDoors({
    required this.db,
    required this.profile,
    required this.actions,
    this.readerDoors = const ReaderDoors(),
    ShareText? shareText,
    bool useDefaultShare = true,
    DateTime Function()? now,
  })  : shareText = shareText ?? (useDefaultShare ? defaultShareText : null),
        now = now ?? DateTime.now;

  Future<void> open(BuildContext context, SearchItem item,
      {int? startSegmentIdx}) async {
    final work = item.work;
    if (work.kind == 'audiobook') {
      await actions.player?.playAudiobook(work);
      return;
    }
    if (item.episode != null) {
      await db.feedsDao
          .markRead(work.id, DateTime.now().millisecondsSinceEpoch);
    }
    final position = await db.spineDao
        .position(profileId: profile.id, workId: work.id);
    final count = await db.spineDao.segmentCount(work.id);
    if (!context.mounted) return;
    await readerDoors.open(context,
        db: db,
        profileId: profile.id,
        work: work,
        position: position,
        segmentCount: count,
        startSegmentIdx: startSegmentIdx);
  }

  /// A transcript hit plays from its sentence when there is audio to
  /// play; otherwise the reader opens on it.
  Future<void> openHit(BuildContext context, TranscriptHit hit) async {
    final player = actions.player;
    if (hit.item.episode?.enclosureUrl != null && player != null) {
      await player.listenFrom(
          hit.item.work,
          core.Position(
              segmentIdx: hit.segmentIdx,
              wordIdx: 0,
              lastModality: core.Modality.listen));
      return;
    }
    await open(context, hit.item, startSegmentIdx: hit.segmentIdx);
  }

  Future<void> share(BuildContext context, SearchItem item) =>
      shareItem(context, item, shareText);
}

/// One history or search row: the shared episode row for anything from a
/// feed, a plain row for books and notes.
class SearchItemTile extends StatelessWidget {
  final SearchDoors doors;
  final SearchItem item;
  final EpisodeListState state;
  final VoidCallback onChanged;

  /// Null where rows can't be selected. Books and notes never can: the
  /// clean-up's actions are about episodes.
  final EpisodeSelection? selection;

  const SearchItemTile(
      {super.key,
      required this.doors,
      required this.item,
      required this.state,
      required this.onChanged,
      this.selection});

  @override
  Widget build(BuildContext context) {
    final work = item.work;
    final episode = item.episode;
    final actions = doors.actions;
    Future<void> open() async {
      await doors.open(context, item);
      onChanged();
    }

    final sel = selection;
    final selecting = sel?.active ?? false;
    if (episode == null) {
      return ListTile(
        key: Key('item-${work.id}'),
        leading: Icon(_kindIcon(work.kind)),
        title: Text(work.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(_kindLabel(work.kind)),
        enabled: !selecting,
        onTap: open,
        trailing: IconButton(
          key: Key('share-${work.id}'),
          tooltip: 'Share',
          icon: const Icon(Icons.share_outlined),
          onPressed: () => doors.share(context, item),
        ),
      );
    }
    final entry = (work: work, episode: episode);
    final isAudio = episode.enclosureUrl != null;
    return EpisodeRow(
      key: Key('item-${work.id}'),
      work: work,
      episode: episode,
      facts: EpisodeRowFacts.of(episode, state,
          downloaded: isAudio && actions.isDownloaded(episode)),
      showTitle: item.showTitle,
      artwork: actions.artworkFor(episode),
      onTap: selecting ? () => sel!.toggle(work.id) : open,
      selected: selecting ? sel!.contains(work.id) : null,
      onLongPress: sel == null
          ? null
          : selecting
              ? () => sel.toggle(work.id)
              : () => sel.enter(work.id),
      onPlay: isAudio
          ? () async {
              await actions.play(work);
              onChanged();
            }
          : null,
      onRead: doors.readerDoors.canOpenTranscript
          ? () async {
              await doors.readerDoors
                  .openTranscript(context, db: doors.db, work: work);
              onChanged();
            }
          : null,
      menuBuilder: (_) => [
        ...actions.commonMenuItems(entry),
        PopupMenuItem(
            key: Key('share-${work.id}'),
            value: 'share',
            child: const Text('Share')),
      ],
      onMenu: (choice) async {
        if (choice == 'share') {
          await doors.share(context, item);
          return;
        }
        await actions.handleCommon(context, choice, entry);
        onChanged();
      },
    );
  }
}

IconData _kindIcon(String kind) => switch (kind) {
      'book' => Icons.menu_book_outlined,
      'audiobook' => Icons.headphones_outlined,
      'article' => Icons.article_outlined,
      _ => Icons.notes_outlined,
    };

String _kindLabel(String kind) => switch (kind) {
      'book' => 'Book',
      'audiobook' => 'Audiobook',
      'article' => 'Article',
      'episode' => 'Episode',
      _ => 'Note',
    };

class _Heading extends StatelessWidget {
  final String text;
  const _Heading(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Semantics(
          header: true,
          child: Text(text, style: Theme.of(context).textTheme.titleSmall),
        ),
      );
}

/// Everything played or read, newest first, under day headings.
class HistoryList extends StatefulWidget {
  final SearchDoors doors;
  final EpisodeSelection? selection;
  const HistoryList({super.key, required this.doors, this.selection});

  @override
  State<HistoryList> createState() => _HistoryListState();
}

class _HistoryListState extends State<HistoryList> {
  List<HistoryEntry>? _entries;
  EpisodeListState _state = EpisodeListState.empty;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = widget.doors;
    final entries = await SearchStore(d.db).history(d.profile.id);
    final state = await EpisodeListState.load(d.db, d.profile.id);
    if (!mounted) return;
    final sel = widget.selection;
    if (sel != null) {
      sel.universe = [
        for (final h in entries)
          if (h.item.episode case final ep?) (work: h.item.work, episode: ep),
      ];
      sel.reload = _load;
    }
    setState(() {
      _entries = entries;
      _state = state;
    });
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    if (entries == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (entries.isEmpty) {
      return const Padding(
        key: Key('history-empty'),
        padding: EdgeInsets.all(24),
        child: Text('Nothing played or read yet. What you play or read '
            'shows up here, newest first.'),
      );
    }
    final groups = groupByDay(entries, (e) => e.atMs, widget.doors.now());
    return ListView(
      key: const Key('history-list'),
      children: [
        for (final g in groups) ...[
          _Heading(g.label, key: Key('day-${g.label}')),
          for (final e in g.items)
            SearchItemTile(
                doors: widget.doors,
                item: e.item,
                state: _state,
                selection: widget.selection,
                onChanged: _load),
        ],
      ],
    );
  }
}

class HistoryScreen extends StatefulWidget {
  final SearchDoors doors;
  const HistoryScreen({super.key, required this.doors});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _selection = EpisodeSelection();
  final _undo = OhUndoController();
  late final EpisodeBulk _bulk = EpisodeBulk(
      actions: widget.doors.actions, selection: _selection, undo: _undo);

  @override
  void initState() {
    super.initState();
    _selection.addListener(_onSelection);
  }

  @override
  void dispose() {
    _selection.removeListener(_onSelection);
    _selection.dispose();
    _undo.dispose();
    super.dispose();
  }

  void _onSelection() => setState(() {});

  @override
  Widget build(BuildContext context) => Scaffold(
        bottomSheet: OhUndoBar(controller: _undo),
        appBar: _selection.active
            ? _bulk.bar(context)
            : AppBar(
                title: const Text('History'),
                actions: [
                  OhBarActions(children: [_selectMenu(_selection)]),
                ],
              ),
        body: CappedBody(
            child: _bulk.scope(
                child: HistoryList(
                    doors: widget.doors, selection: _selection))),
      );
}

/// The bar's worded way into selection, for anyone who can't long-press.
Widget _selectMenu(EpisodeSelection selection) => OhBarOverflow<String>(
      key: const Key('select-more'),
      onSelected: (_) => selection.enter(),
      itemBuilder: (_) => const [
        PopupMenuItem(
            key: Key('select-episodes'),
            value: 'select',
            child: Text('Select')),
      ],
    );

class SearchScreen extends StatefulWidget {
  final SearchDoors doors;

  /// How long typing must pause before a search runs.
  final Duration debounce;

  /// The queries; a test hands in one that fails.
  final SearchStore? store;

  const SearchScreen(
      {super.key,
      required this.doors,
      this.debounce = const Duration(milliseconds: 300),
      this.store});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _field = TextEditingController();
  late final SearchStore _store =
      widget.store ?? SearchStore(widget.doors.db);
  Timer? _timer;
  String _query = '';
  SearchResults? _results;
  bool _failed = false;
  EpisodeListState _state = EpisodeListState.empty;
  final _selection = EpisodeSelection();
  final _undo = OhUndoController();
  late final EpisodeBulk _bulk = EpisodeBulk(
      actions: widget.doors.actions, selection: _selection, undo: _undo);

  /// The field asks for the keyboard when the screen opens, and only
  /// then: leaving selection rebuilds it, and a keyboard springing up
  /// over the rows just acted on is not what anyone asked for.
  bool _autofocus = true;

  @override
  void initState() {
    super.initState();
    _selection.addListener(_onSelection);
    WidgetsBinding.instance.addPostFrameCallback((_) => _autofocus = false);
  }

  void _onSelection() => setState(() {});

  /// Each search's own number, so a slow early answer never replaces a
  /// later one.
  int _generation = 0;

  @override
  void dispose() {
    _timer?.cancel();
    _field.dispose();
    _selection.removeListener(_onSelection);
    _selection.dispose();
    _undo.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    // New words, new rows: a selection made against the old ones would
    // act on rows no longer on screen.
    _selection.exit();
    _timer?.cancel();
    _timer = Timer(widget.debounce, () => _run(text));
  }

  Future<void> _run(String text) async {
    final gen = ++_generation;
    final query = text.trim();
    if (query.isEmpty) {
      setState(() {
        _query = '';
        _results = null;
        _failed = false;
      });
      return;
    }
    final d = widget.doors;
    try {
      final results = await _store.search(d.profile.id, query);
      final state = await EpisodeListState.load(d.db, d.profile.id);
      if (!mounted || gen != _generation) return;
      _selection
        ..universe = [
          for (final i in results.items)
            if (i.episode case final ep?) (work: i.work, episode: ep),
        ]
        ..reload = () => _run(_field.text);
      setState(() {
        _query = query;
        _results = results;
        _state = state;
        _failed = false;
      });
    } catch (_) {
      // Stale results under a new query would read as the answer to it.
      if (!mounted || gen != _generation) return;
      setState(() {
        _query = query;
        _results = null;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      bottomSheet: OhUndoBar(controller: _undo),
      appBar: _selection.active ? _bulk.bar(context) : AppBar(
        actions: [OhBarActions(children: [_selectMenu(_selection)])],
        title: TextField(
          key: const Key('search-field'),
          controller: _field,
          autofocus: _autofocus,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Titles, shows, what was said',
            border: InputBorder.none,
          ),
          onChanged: _onChanged,
          onSubmitted: (t) {
            _timer?.cancel();
            _run(t);
          },
        ),
      ),
      body: CappedBody(child: _bulk.scope(child: _body())),
    );
  }

  Widget _body() {
    if (_failed) {
      return const Padding(
        key: Key('search-failed'),
        padding: EdgeInsets.all(24),
        child: Text('Search isn’t working right now. Try again, or look '
            'through History.'),
      );
    }
    final results = _results;
    if (_query.isEmpty || results == null) {
      // Before anything is typed, history is the likeliest place the
      // thing they are after already is.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Heading('History', key: Key('search-history-heading')),
          Expanded(
              child: HistoryList(doors: widget.doors, selection: _selection)),
        ],
      );
    }
    if (results.isEmpty) {
      return Padding(
        key: const Key('search-nothing'),
        padding: const EdgeInsets.all(24),
        child: Text('Nothing matches “$_query”.'),
      );
    }
    return ListView(
      key: const Key('search-results'),
      children: [
        if (results.items.isNotEmpty) ...[
          const _Heading('Episodes and articles',
              key: Key('search-items-heading')),
          for (final item in results.items)
            SearchItemTile(
                doors: widget.doors,
                item: item,
                state: _state,
                selection: _selection,
                onChanged: () => _run(_field.text)),
        ],
        if (results.said.isNotEmpty) ...[
          const _Heading('Said in', key: Key('search-said-heading')),
          for (final hit in results.said) _SaidTile(doors: widget.doors, hit: hit),
        ],
      ],
    );
  }
}

class _SaidTile extends StatelessWidget {
  final SearchDoors doors;
  final TranscriptHit hit;
  const _SaidTile({required this.doors, required this.hit});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = hit.tStartMs;
    final id = '${hit.item.work.id}-${hit.segmentIdx}';
    return ListTile(
      key: Key('said-$id'),
      leading: const Icon(Icons.format_quote),
      title: Text.rich(
        TextSpan(children: [
          for (final p in parseSnippet(hit.snippet))
            TextSpan(
                text: p.text,
                style: p.match
                    ? const TextStyle(fontWeight: FontWeight.w800)
                    : null),
        ]),
        style: theme.textTheme.bodyLarge,
      ),
      subtitle: Text(
        [hit.item.work.title, if (t != null) formatClock(t)].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => doors.openHit(context, hit),
      trailing: IconButton(
        key: Key('share-said-$id'),
        tooltip: 'Share',
        icon: const Icon(Icons.share_outlined),
        onPressed: () => doors.share(context, hit.item),
      ),
    );
  }
}
