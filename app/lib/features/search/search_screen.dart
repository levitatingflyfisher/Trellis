/// History and search (ADR-0016 section 4): one box over titles, show
/// names, show notes and transcripts, and, before anything is typed, what
/// was played or read, newest first.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:loom_core/loom_core.dart' as core;
import 'package:openhearth_design/openhearth_design.dart';

import '../../db/database.dart' hide Alignment;
import '../episodes/episode_actions.dart';
import '../works/work_menu.dart';
import '../works/work_open.dart';
import '../works/work_row.dart';
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

  /// The one shared open every list routes its rows through.
  WorkDoors get works => WorkDoors(
      db: db,
      profileId: profile.id,
      readerDoors: readerDoors,
      player: actions.player,
      actions: actions);

  /// Completes with a removal's outcome when the page was closed by
  /// Remove; null otherwise.
  Future<Future<bool>?> open(BuildContext context, SearchItem item,
      {int? startSegmentIdx}) async {
    final entry = (work: item.work, episode: item.episode);
    if (startSegmentIdx == null) return works.open(context, entry);
    await works.read(context, entry, startSegmentIdx: startSegmentIdx);
    return null;
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

/// One history or search row: the shared row, for an episode or a book
/// alike.
class SearchItemTile extends StatelessWidget {
  final SearchDoors doors;
  final SearchItem item;
  final WorkListState state;
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
    final works = doors.works;
    final entry = (work: work, episode: episode);
    Future<void> open() async {
      final removal = await doors.open(context, item);
      onChanged();
      // Removed from its page: refresh once the Undo goes.
      removal?.then((_) => onChanged());
    }

    final sel = episode == null ? null : selection;
    final selecting = selection?.active ?? false;
    final isAudio = episode?.enclosureUrl != null || work.kind == 'audiobook';
    return WorkRow(
      key: Key('item-${work.id}'),
      work: work,
      episode: episode,
      facts: WorkRowFacts.of(work, episode, state,
          downloaded: episode != null && actions.isDownloaded(episode)),
      showTitle: item.showTitle,
      artwork: episode == null ? null : actions.artworkFor(episode),
      // A book can't join an episode selection; while one is under way
      // its row stays put rather than opening under the listener's thumb.
      onTap: selecting
          ? (sel == null ? null : () => sel.toggle(work.id))
          : open,
      selected: selecting && sel != null ? sel.contains(work.id) : null,
      onLongPress: sel == null
          ? null
          : selecting
              ? () => sel.toggle(work.id)
              : () => sel.enter(work.id),
      onPlay: isAudio
          ? () async {
              await works.play(work);
              onChanged();
            }
          : null,
      onRead: works.canRead(entry)
          ? () async {
              await works.readFromRow(context, entry);
              onChanged();
            }
          : null,
      menuBuilder: (_) => workMenuItems(actions, entry,
          transcribed: state.transcribed.contains(work.id),
          sourceLang: state.sourceLangOf(entry)),
      onMenu: (choice) async {
        // These doors may carry their own share (a test's, the web's).
        if (choice == 'share') {
          await doors.share(context, item);
          return;
        }
        await actions.handleShared(context, choice, entry,
            showTitle: item.showTitle);
        onChanged();
      },
    );
  }
}

class _Heading extends StatelessWidget {
  final String text;

  /// How many the section holds in all, beside its name.
  final int? count;
  const _Heading(this.text, {super.key, this.count});

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleSmall;
    final n = count;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Semantics(
        header: true,
        label: n == null ? null : '$text, $n',
        child: ExcludeSemantics(
          excluding: n != null,
          child: Row(
            children: [
              Expanded(child: Text(text, style: style)),
              if (n != null) Text('$n', style: style),
            ],
          ),
        ),
      ),
    );
  }
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
  WorkListState _state = WorkListState.empty;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = widget.doors;
    final entries = await SearchStore(d.db).history(d.profile.id);
    final state = await WorkListState.load(d.db, d.profile.id, entries: [
      for (final h in entries) (work: h.item.work, episode: h.item.episode),
    ]);
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

  /// Words typed elsewhere (the Subscriptions filter) to search at once.
  final String? initialQuery;

  const SearchScreen(
      {super.key,
      required this.doors,
      this.debounce = const Duration(milliseconds: 300),
      this.store,
      this.initialQuery});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _field = TextEditingController();
  late final SearchStore _store =
      widget.store ?? SearchStore(widget.doors.db);
  Timer? _timer;

  /// The words the rows answer, and the words in the box now. They differ
  /// while a search is pending, and the old rows are dimmed meanwhile.
  String _query = '';
  String _typed = '';
  bool _pending = false;
  SearchResults? _results;
  bool _failed = false;

  /// How far the index's fill after an upgrade has come; null once done.
  int? _indexProgress;
  bool _indexStalled = false;

  /// Each section's rows so far: the first page, then whatever "Show all"
  /// has paged in.
  List<Feed> _shows = const [];
  List<SearchItem> _titles = const [];
  List<SearchItem> _notes = const [];
  List<TranscriptHit> _said = const [];
  final Set<_Section> _expanded = {};
  final Set<_Section> _paging = {};
  WorkListState _state = WorkListState.empty;
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
    _readProgress();
    final initial = widget.initialQuery?.trim() ?? '';
    if (initial.isNotEmpty) {
      _field.text = initial;
      _typed = initial;
      _pending = true;
      _run(initial);
    }
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
    // Pending from the first keystroke, so the debounce never shows
    // History, or the last answer as if it were this one's.
    setState(() {
      _typed = text.trim();
      _pending = _typed.isNotEmpty;
    });
    _timer = Timer(widget.debounce, () => _run(text));
  }

  Future<void> _run(String text) async {
    final gen = ++_generation;
    final query = text.trim();
    if (query.isEmpty) {
      setState(() {
        _query = '';
        _typed = '';
        _pending = false;
        _results = null;
        _failed = false;
      });
      return;
    }
    setState(() => _pending = true);
    final d = widget.doors;
    try {
      final results = await _store.search(d.profile.id, query);
      final state = await WorkListState.load(d.db, d.profile.id, entries: [
        for (final i in results.items) (work: i.work, episode: i.episode),
      ]);
      if (!mounted || gen != _generation) return;
      final again = query == _query;
      setState(() {
        _query = query;
        _results = results;
        _shows = results.shows;
        _titles = results.titleSection.rows;
        _notes = results.notesSection.rows;
        _said = results.said;
        // A re-run of the same words (after acting on a row) keeps the
        // sections that were open; they page in again as they show.
        if (!again) _expanded.clear();
        _paging.clear();
        _state = state;
        _failed = false;
        _pending = false;
      });
      _syncSelection();
      _readProgress();
    } catch (_) {
      // Stale results under a new query would read as the answer to it.
      if (!mounted || gen != _generation) return;
      setState(() {
        _query = query;
        _results = null;
        _failed = true;
        _pending = false;
      });
    }
  }

  Future<void> _readProgress() async {
    try {
      final p = await _store.indexProgress;
      final stalled = p != null && await _store.indexStalled;
      if (mounted && (p != _indexProgress || stalled != _indexStalled)) {
        setState(() {
          _indexProgress = p;
          _indexStalled = stalled;
        });
      }
    } catch (_) {
      // Only a hint; search works without it.
    }
  }

  void _syncSelection() {
    _selection
      ..universe = [
        for (final i in [..._titles, ..._notes])
          if (i.episode case final ep?) (work: i.work, episode: ep),
      ]
      ..reload = () => _run(_field.text);
  }

  /// Pages in the next part of an open section.
  Future<void> _loadMore(_Section section) async {
    final results = _results;
    if (results == null || !_paging.add(section)) return;
    final gen = _generation;
    final query = _query;
    final d = widget.doors;
    final profileId = d.profile.id;
    try {
      switch (section) {
        case _Section.shows:
          final all = await _store.showsMatching(profileId, query);
          if (!mounted || gen != _generation) return;
          setState(() => _shows = all);
        case _Section.titles || _Section.notes:
          final titles = section == _Section.titles;
          final loaded = titles ? _titles : _notes;
          final page = await _store.itemsPage(profileId, query,
              titles ? SearchTier.titles : SearchTier.notes,
              offset: loaded.length);
          final state = await _state.including(d.db, [
            for (final i in page) (work: i.work, episode: i.episode),
          ]);
          if (!mounted || gen != _generation) return;
          setState(() {
            if (titles) {
              _titles = [..._titles, ...page];
            } else {
              _notes = [..._notes, ...page];
            }
            _state = state.withSizesFrom(_state);
          });
          _syncSelection();
        case _Section.said:
          final page = await _store.saidPage(profileId, query,
              offset: _said.length);
          if (!mounted || gen != _generation) return;
          setState(() => _said = [..._said, ...page]);
      }
    } catch (_) {
      // The next time the row shows, it asks again.
    } finally {
      if (mounted && gen == _generation) {
        setState(() => _paging.remove(section));
      }
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
            hintText: 'Titles, shows, notes, what was said',
            border: InputBorder.none,
          ),
          onChanged: _onChanged,
          onSubmitted: (t) {
            _timer?.cancel();
            _run(t);
          },
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: _pending
              ? const LinearProgressIndicator(
                  key: Key('search-pending'), minHeight: 3)
              : const SizedBox(height: 3),
        ),
      ),
      body: CappedBody(
          child: _bulk.scope(
              child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Until the index is filled search answers by plain matching,
          // which finds fewer forms of a word; the line says why.
          if (_indexProgress case final p?)
            Padding(
              key: const Key('search-updating'),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                  _indexStalled
                      ? 'Updating search stopped at $p%. It will try again '
                          'the next time Trellis starts.'
                      : 'Updating search… $p%',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          Expanded(child: _body()),
        ],
      ))),
    );
  }

  Widget _body() {
    if (_typed.isEmpty) {
      // Before anything is typed, history is the likeliest place the
      // thing they are after already is. Never once something is.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Heading('History', key: Key('search-history-heading')),
          Expanded(
              child: HistoryList(doors: widget.doors, selection: _selection)),
        ],
      );
    }
    if (_failed && !_pending) {
      return const Padding(
        key: Key('search-failed'),
        padding: EdgeInsets.all(24),
        child: Text('Search isn’t working right now. Try again, or look '
            'through History.'),
      );
    }
    final results = _results;
    if (results == null) {
      return const Padding(
        key: Key('search-waiting'),
        padding: EdgeInsets.all(24),
        child: Text('Searching…'),
      );
    }
    // The rows answer other words than the ones in the box: dimmed, and
    // not to be acted on, until this search answers.
    final stale = _query != _typed;
    if (results.isEmpty && !stale) {
      return Padding(
        key: const Key('search-nothing'),
        padding: const EdgeInsets.all(24),
        child: Text('Nothing matches “$_query”. Search looks in titles, '
            'show names, show notes and transcripts.'),
      );
    }
    final list = ListView(
      key: const Key('search-results'),
      children: [
        ..._section(_Section.shows, 'Shows', results.showSection.count,
            _shows, (feed) => _ShowTile(doors: widget.doors, feed: feed)),
        ..._section(_Section.titles, 'In titles', results.titleSection.count,
            _titles, _itemTile),
        ..._section(_Section.notes, 'In the text',
            results.notesSection.count, _notes, _itemTile),
        ..._section(_Section.said, 'Said in', results.saidSection.count,
            _said, (hit) => _SaidTile(doors: widget.doors, hit: hit)),
      ],
    );
    if (!stale) return list;
    return Opacity(
      key: const Key('search-stale'),
      opacity: 0.4,
      child: IgnorePointer(child: ExcludeSemantics(child: list)),
    );
  }

  Widget _itemTile(SearchItem item) => SearchItemTile(
      doors: widget.doors,
      item: item,
      state: _state,
      selection: _selection,
      onChanged: () => _run(_field.text));

  /// A heading with the section's true count, its rows so far, and
  /// either "Show all" or, once open, a row that pages in the rest as it
  /// scrolls into view.
  List<Widget> _section<T>(_Section section, String title, int count,
      List<T> rows, Widget Function(T) tile) {
    if (count == 0) return const [];
    final open = _expanded.contains(section);
    return [
      _Heading(title, key: Key('search-${section.name}-heading'), count: count),
      for (final r in rows) tile(r),
      if (rows.length < count)
        open
            ? _PageLoader(
                key: Key('search-${section.name}-more-${rows.length}'),
                onShown: () => _loadMore(section))
            : Align(
                alignment: AlignmentDirectional.centerStart,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: TextButton(
                    key: Key('search-${section.name}-all'),
                    style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48)),
                    onPressed: () {
                      setState(() => _expanded.add(section));
                    },
                    child: Text('Show all $count'),
                  ),
                ),
              ),
    ];
  }
}

enum _Section { shows, titles, notes, said }

class _ShowTile extends StatelessWidget {
  final SearchDoors doors;
  final Feed feed;
  const _ShowTile({required this.doors, required this.feed});

  @override
  Widget build(BuildContext context) => ListTile(
        key: Key('show-${feed.id}'),
        leading: Icon(
            feed.origin == 'blog' ? Icons.article_outlined : Icons.podcasts),
        title: Text(feed.title.isEmpty ? feed.url : feed.title,
            maxLines: 2, overflow: TextOverflow.ellipsis),
        onTap: () => doors.actions.openShow?.call(context, feed),
      );
}

/// The last row of an open section with more to come: it asks for the
/// next page when it is first built, which a lazy list does only as it
/// scrolls into view.
class _PageLoader extends StatefulWidget {
  final VoidCallback onShown;
  const _PageLoader({super.key, required this.onShown});

  @override
  State<_PageLoader> createState() => _PageLoaderState();
}

class _PageLoaderState extends State<_PageLoader> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onShown();
    });
  }

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(
          child: SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
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
