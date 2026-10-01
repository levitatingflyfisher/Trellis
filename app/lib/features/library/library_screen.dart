import 'dart:async';
import 'dart:convert';

import 'package:comms_core/comms_core.dart';
import 'package:flutter/material.dart';
import 'package:intake_core/intake_core.dart' show EpubTooLargeException;
import 'package:openhearth_design/openhearth_design.dart';

import '../../db/database.dart' hide Alignment;
import '../../net/io_fetcher.dart';
import '../../services/device_services.dart';
import '../intake/epub_intake.dart';
import '../intake/gutenberg_screen.dart';
import '../intake/paste_intake.dart';
import '../intake/url_intake.dart';
import '../player/player_controller.dart';
import '../reader/reader_doors.dart';
import '../reader/speech/speech_engine.dart';
import '../reader/speech/speech_temp_files.dart';
import '../reader/translation/translation_service.dart';
import '../settings/theme_preference.dart';
import '../episodes/episode_actions.dart';
import '../works/work_menu.dart';
import '../works/work_open.dart';
import '../works/remove_undo.dart';
import '../works/work_row.dart';
import '../search/search_store.dart';
import 'library_filter_screen.dart';
import 'library_filter_sheet.dart';
import 'library_query.dart';
import '../shared/capped_body.dart';

typedef _Entry = ({Work work, Episode? episode, String? feedTitle});

/// One reader's works: pinned first, then newest, each in the shared row
/// every list of works uses; progress is the cursor law's numerator over
/// the segment count. The empty state is an invitation,
/// not a void (ADR-0003 — no guilt, no streaks).
class LibraryScreen extends StatefulWidget {
  final AppDatabase db;
  final Profile profile;
  final VoidCallback onSwitchProfile;

  /// Opens the "On this device" model manager; the shell wires it.
  final VoidCallback? onOpenModels;

  /// The HTTP seam for "From the web" intake. Optional so existing call
  /// sites keep compiling; when the shell does not pass one, the real
  /// [IoHttpFetcher] is built lazily on first use — tests always inject a
  /// ScriptedFetcher, so no test ever constructs a socket-capable client.
  final HttpFetcher? fetcher;

  /// The speak-mode voice, handed on to every reader this screen opens —
  /// null lets [ReaderScreen] fall back to the platform speaker.
  final TtsSpeaker? tts;

  /// The web tier's fetch-routing decision, handed on
  /// to the two web-fetching doors this screen opens — the
  /// [DeviceServices.localMlAvailable] threading pattern's sibling.
  final WebFetchLane lane;

  /// Whether this tier can run local ML at all — every reader this screen
  /// opens uses it to decide whether the neural-voice hint could ever be
  /// true (ADR-0006).
  final bool localMlAvailable;

  /// Resolves the neural voice for a work's language (ADR-0006) — the
  /// shell closes over `DeviceServices.resolveSpeechEngine`; null keeps
  /// every reader this screen opens on the system voice.
  final Future<SynthesisSpeechEngine?> Function({String? lang})?
      resolveSpeechEngine;

  /// Campaign 4 Phase 3's on-device dictionary lookup — the shell closes
  /// over `DeviceServices.lookupDefinition`, same threading shape as
  /// [resolveSpeechEngine]; null keeps every reader this screen opens on
  /// the sheet's own honest empty state.
  final Future<String?> Function(String word)? lookupDefinition;

  /// Where a reader this screen opens writes per-sentence WAV temp files
  /// while speaking neurally — the shell closes over
  /// `DeviceServices.createSpeechTempFiles` (the location app start
  /// sweeps); null falls back to `ReaderScreen`'s own plain-systemTemp
  /// default.
  final SpeechTempFiles Function()? createSpeechTempFiles;

  /// The study crown's "Listen from here" — threaded on to every reader
  /// this screen opens, same shape as [tts]/[resolveSpeechEngine]; null
  /// (existing call sites) just hides the button.
  final PlayerController? player;

  /// Translation for the readers this opens (1.5.5); null hides
  /// Translate. See [TranslationService].
  final TranslationService? translation;

  /// The audiobook door (Campaign 7, ADR-0013): pick, confirm a title,
  /// copy. Null hides the "Audiobook" option — the shell only wires this
  /// when [localMlAvailable], the same law gating every other real-file
  /// door in this app (a web-tier picker can never return a usable path
  /// for the sync-copy this door needs).
  final Future<int?> Function(BuildContext)? onImportAudiobook;

  /// Deletes an audiobook's copied files from disk (ADR-0013) — the
  /// shell wires `services.audiobookDirFor(workId)`'s deletion. Called
  /// BEFORE the DB rows go, so a mid-delete failure leaves an orphaned
  /// directory (recoverable by re-importing) rather than a DB row
  /// pointing at nothing.
  final void Function(int workId)? onDeleteAudiobookFiles;

  /// What a feed item's row can do and knows (artwork, downloads); the
  /// shell's own, so its menu matches Latest's. Null builds a bare one.
  final EpisodeActions? actions;

  const LibraryScreen(
      {super.key,
      required this.db,
      required this.profile,
      required this.onSwitchProfile,
      this.onOpenModels,
      this.fetcher,
      this.tts,
      this.lane = WebFetchLane.direct,
      this.localMlAvailable = true,
      this.resolveSpeechEngine,
      this.lookupDefinition,
      this.createSpeechTempFiles,
      this.player,
      this.translation,
      this.onImportAudiobook,
      this.onDeleteAudiobookFiles,
      this.actions});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<_Entry>? _entries;
  LibraryQuery? _activeQuery;

  /// What the search engine found for the filter's words, and the words
  /// it answers; the last answer stands while a new one is pending.
  Set<int>? _textMatches;
  String _textAnswered = '';
  bool _textPending = false;
  Timer? _textTimer;
  int _textGeneration = 0;

  /// Every filter change comes through here, so the words reach the
  /// search engine (debounced, as Latest's box is).
  void _setQuery(LibraryQuery? q) {
    setState(() => _activeQuery = q == null || q.isEmpty ? null : q);
    _textTimer?.cancel();
    final words = _activeQuery?.textSearch?.trim() ?? '';
    if (words.isEmpty) {
      setState(() => _textPending = false);
      return;
    }
    if (words == _textAnswered && !_textPending) return;
    setState(() => _textPending = true);
    _textTimer =
        Timer(const Duration(milliseconds: 300), () => _searchText(words));
  }

  Future<void> _searchText(String words) async {
    final gen = ++_textGeneration;
    try {
      final found = await SearchStore(widget.db)
          .libraryMatches(widget.profile.id, words);
      if (!mounted || gen != _textGeneration) return;
      setState(() {
        _textMatches = found;
        _textAnswered = words;
        _textPending = false;
      });
    } catch (_) {
      if (!mounted || gen != _textGeneration) return;
      setState(() => _textPending = false);
    }
  }

  @override
  void dispose() {
    _textTimer?.cancel();
    super.dispose();
  }

  /// Works removed but still on offer to Undo (the fleet's delete ruling:
  /// a deliberate delete doesn't ask, and its Undo never times out). They
  /// leave the list at once; the rows go only when the offer is let go.
  final Set<int> _removing = {};
  List<SavedViewRow> _savedViews = const [];

  SpineDao get _dao => widget.db.spineDao;

  late final HttpFetcher _fetcher = widget.fetcher ?? IoHttpFetcher();

  @override
  void initState() {
    super.initState();
    _load();
  }

  WorkListState _rowState = WorkListState.empty;

  late final EpisodeActions _actions = widget.actions ??
      EpisodeActions(
          db: widget.db, profileId: widget.profile.id, player: widget.player);

  /// One query for the works, then a few for every row's facts at once:
  /// never a query per row.
  Future<void> _load() async {
    final queryEntries =
        await widget.db.libraryDao.libraryQueryEntriesOf(widget.profile.id);
    final entries = <_Entry>[
      for (final qe in queryEntries)
        (work: qe.work, episode: qe.episode, feedTitle: qe.feedTitle)
    ];
    final rowState = await WorkListState.load(widget.db, widget.profile.id,
        entries: [for (final e in entries) (work: e.work, episode: e.episode)]);
    entries.sort((a, b) {
      if (a.work.pinned != b.work.pinned) return a.work.pinned ? -1 : 1;
      return b.work.id.compareTo(a.work.id); // newest first
    });
    final savedViews = await widget.db.libraryDao.savedViewsOf(widget.profile.id);
    if (!mounted) return;
    _actions.forgetArtwork();
    setState(() {
      _entries = entries;
      _rowState = rowState;
      _savedViews = savedViews;
    });
    // What was kept or removed may have changed what the words find.
    final words = _activeQuery?.textSearch?.trim() ?? '';
    if (words.isNotEmpty) await _searchText(words);
  }

  /// The filtered view of [_entries] — pure, re-evaluated on every build
  /// rather than stored, so applying/clearing a filter never needs a DB
  /// round-trip.
  List<_Entry>? get _liveEntries => _entries == null
      ? null
      : [
          for (final e in _entries!)
            if (!_removing.contains(e.work.id)) e
        ];

  List<_Entry> get _visibleEntries {
    final entries = _liveEntries ?? const [];
    final query = _activeQuery;
    if (query == null) return entries;
    return [
      for (final e in entries)
        if (matchesLibraryQuery(
            (work: e.work, episode: e.episode, feedTitle: e.feedTitle), query,
            textMatches: _textMatches))
          e
    ];
  }

  /// The filter icon (Campaign 5 Phase 2; modernized to a live modal sheet
  /// in Campaign 9 Phase 1 — the user called the old pushed-screen-with-
  /// an-Apply-button flow "dated"): no active filter opens the sheet,
  /// live-applying to [_visibleEntries] as it's edited; an active one
  /// clears in one tap without any screen at all — the reachable, low-
  /// friction path (ergonomic-ux: state is a design surface, not an
  /// afterthought). Saved-view management stays a pushed screen, reached
  /// from a door inside the sheet.
  Future<void> _openFilter() async {
    final active = _activeQuery;
    if (active != null && !active.isEmpty) {
      _setQuery(null);
      return;
    }
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => LibraryFilterSheet(
        db: widget.db,
        profileId: widget.profile.id,
        initial: active ?? const LibraryQuery(),
        onChanged: _setQuery,
      ),
    );
    if (action != openSavedViewsManagement || !mounted) return;
    final result = await Navigator.of(context).push<LibraryQuery>(
        MaterialPageRoute(
            builder: (_) => LibraryFilterScreen(
                db: widget.db,
                profileId: widget.profile.id,
                currentQuery: _activeQuery ?? const LibraryQuery())));
    if (!mounted) return;
    if (result != null) {
      _setQuery(result);
    }
    await _load(); // a view may have been created/deleted/reordered too
  }

  void _applySavedView(SavedViewRow v) {
    final query = LibraryQuery.fromJson(
        jsonDecode(v.queryJson) as Map<String, Object?>);
    _setQuery(query);
  }

  Future<void> _pasteText() async {
    final workId = await showPasteIntakeDialog(context,
        db: widget.db, profileId: widget.profile.id);
    if (workId != null) await _load();
  }

  Future<void> _importEpub() async {
    try {
      final workId =
          await pickAndImportEpub(db: widget.db, profileId: widget.profile.id);
      if (workId != null) await _load();
    } on EpubTooLargeException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } on FormatException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("That file couldn’t be read as an EPUB.")));
    }
  }

  Future<void> _fromWeb() async {
    final workId = await Navigator.of(context).push<int>(MaterialPageRoute(
        builder: (_) => UrlIntakeScreen(
            db: widget.db,
            profileId: widget.profile.id,
            fetcher: _fetcher,
            lane: widget.lane)));
    if (workId != null) await _load();
  }

  Future<void> _fromGutenberg() async {
    final workId = await Navigator.of(context).push<int>(MaterialPageRoute(
        builder: (_) => GutenbergSearchScreen(
            db: widget.db,
            profileId: widget.profile.id,
            fetcher: _fetcher,
            lane: widget.lane)));
    if (workId != null) await _load();
  }

  Future<void> _importAudiobook() async {
    final onImportAudiobook = widget.onImportAudiobook;
    if (onImportAudiobook == null) return;
    final workId = await onImportAudiobook(context);
    if (workId != null) await _load();
  }

  void _addSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.content_paste),
              title: const Text('Paste text'),
              onTap: () {
                Navigator.pop(sheet);
                _pasteText();
              },
            ),
            ListTile(
              leading: const Icon(Icons.menu_book_outlined),
              title: const Text('Import an EPUB'),
              onTap: () {
                Navigator.pop(sheet);
                _importEpub();
              },
            ),
            ListTile(
              leading: const Icon(Icons.public),
              title: const Text('From the web'),
              onTap: () {
                Navigator.pop(sheet);
                _fromWeb();
              },
            ),
            ListTile(
              leading: const Icon(Icons.local_library_outlined),
              title: const Text('Project Gutenberg'),
              onTap: () {
                Navigator.pop(sheet);
                _fromGutenberg();
              },
            ),
            if (widget.onImportAudiobook != null)
              ListTile(
                leading: const Icon(Icons.headphones_outlined),
                title: const Text('Audiobook (pick files)'),
                onTap: () {
                  Navigator.pop(sheet);
                  _importAudiobook();
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _togglePin(_Entry e) async {
    final pinning = !e.work.pinned;
    await _dao.setPinned(e.work.id, pinning);
    // A pin is the user's hand on the work (ADR-0002): it also promotes.
    if (pinning) await _dao.promoteWork(e.work.id);
    await _load();
  }

  /// Remove is a deliberate menu choice, so it doesn't ask (fleet delete
  /// ruling). The work leaves the list at once and the bar offers Undo
  /// until the person dismisses it, removes something else or leaves the
  /// screen; only then does the removal land. A process killed meanwhile
  /// changes nothing. A feed item only leaves the Library: Latest keeps
  /// it, so the words say "from Library" (ADR-0019 §1).
  void _remove(_Entry e) {
    // The one shared Remove (remove_undo.dart), so the work page's means
    // the same. Campaign 7 (ADR-0013): a delete only ever removes DB rows
    // — an audiobook's copied bytes on disk go through the callback, or
    // Remove silently leaks the whole book.
    _hideWhile(
      e.work.id,
      removeWithUndo(
        ScaffoldMessenger.of(context),
        db: widget.db,
        work: e.work,
        fromFeed: e.episode != null,
        deleteAudiobookFiles: widget.onDeleteAudiobookFiles,
      ),
    );
  }

  /// Keeps [id] out of the list while its removal's Undo stands, then
  /// shows the list as it is.
  void _hideWhile(int id, Future<bool> removal) {
    setState(() => _removing.add(id));
    removal.then((_) async {
      _removing.remove(id);
      if (mounted) await _load();
    });
  }

  ReaderDoors get _readerDoors => ReaderDoors(
      tts: widget.tts,
      localMlAvailable: widget.localMlAvailable,
      resolveSpeechEngine: widget.resolveSpeechEngine,
      lookupDefinition: widget.lookupDefinition,
      createSpeechTempFiles: widget.createSpeechTempFiles,
      player: widget.player,
      translation: widget.translation);

  WorkDoors get _doors => WorkDoors(
      db: widget.db,
      profileId: widget.profile.id,
      readerDoors: _readerDoors,
      actions: _actions);

  /// The row's tap, through the one shared open: the work's page.
  Future<void> _open(_Entry e) async {
    final removal =
        await _doors.open(context, (work: e.work, episode: e.episode));
    if (removal != null && mounted) _hideWhile(e.work.id, removal);
    if (!mounted) return;
    await _load(); // progress may have moved
  }

  @override
  Widget build(BuildContext context) {
    final entries = _liveEntries;
    final hasFilter = _activeQuery != null;
    final theme = ThemePreferenceScope.maybeOf(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        // Icon + word for what matters here; rarer doors in a worded menu
        // (fleet ruling on top bars; audit rank 3).
        actions: [
          OhBarActions(children: [
            OhBarAction(
              key: const Key('open-filter'),
              icon: hasFilter ? Icons.filter_alt_off : Icons.filter_alt_outlined,
              label: hasFilter ? 'Clear filter' : 'Filter',
              onPressed: _openFilter,
            ),
            OhBarOverflow<String>(
              key: const Key('library-more'),
              onSelected: (v) => switch (v) {
                'models' => widget.onOpenModels?.call(),
                final v when isThemeMenuValue(v) =>
                  chooseThemeFromMenu(theme!, v),
                _ => widget.onSwitchProfile(),
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  key: const Key('profile-switcher'),
                  value: 'switch',
                  child: Text('Switch reader (${widget.profile.name})',
                      overflow: TextOverflow.ellipsis),
                ),
                if (widget.onOpenModels != null)
                  const PopupMenuItem(
                    key: Key('open-models'),
                    value: 'models',
                    child: Text('On this device'),
                  ),
                if (theme != null) ...themeMenuItems(theme),
              ],
            ),
          ]),
        ],
      ),
      floatingActionButton: (entries == null || entries.isEmpty)
          ? null
          : FloatingActionButton.extended(
              onPressed: _addSheet,
              icon: const Icon(Icons.add),
              label: const Text('Add')),
      body: CappedBody(child: switch (entries) {
        null => const Center(child: CircularProgressIndicator()),
        [] => _EmptyState(
            onPaste: _pasteText,
            onEpub: _importEpub,
            onWeb: _fromWeb,
            onGutenberg: _fromGutenberg,
            onAudiobook:
                widget.onImportAudiobook != null ? _importAudiobook : null),
        _ => Column(
            children: [
              if (_savedViews.isNotEmpty) _savedViewChips(),
              SizedBox(
                height: 3,
                child: _textPending
                    ? const LinearProgressIndicator(
                        key: Key('library-search-pending'), minHeight: 3)
                    : null,
              ),
              Expanded(child: _libraryList(_visibleEntries)),
            ],
          ),
      }),
    );
  }

  /// Saved views as tappable chips (Campaign 5 Phase 2) — reordering and
  /// deleting live on the filter screen; this row is the one-tap-apply
  /// fast path.
  Widget _savedViewChips() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          for (final v in _savedViews)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ActionChip(
                key: Key('saved-view-${v.name}'),
                label: Text(v.name),
                onPressed: () => _applySavedView(v),
              ),
            ),
        ],
      ),
    );
  }

  Widget _libraryList(List<_Entry> visible) {
    if (visible.isEmpty) {
      // A real filter that matched nothing is a different state from an
      // empty library — the intake invitation would be misleading here.
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Nothing matches this filter.',
              textAlign: TextAlign.center),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: visible.length,
      itemBuilder: (_, i) => _workTile(visible[i]),
    );
  }

  Widget _workTile(_Entry e) {
    final work = e.work;
    final episode = e.episode;
    final entry = (work: work, episode: episode);
    final isAudio = episode?.enclosureUrl != null || work.kind == 'audiobook';
    return WorkRow(
      work: work,
      episode: episode,
      facts: WorkRowFacts.of(work, episode, _rowState,
          downloaded: episode != null && _actions.isDownloaded(episode)),
      showTitle: e.feedTitle,
      artwork: episode == null ? null : _actions.artworkFor(episode),
      onTap: () => _open(e),
      onPlay: isAudio && widget.player != null
          ? () async {
              await _doors.play(work);
              if (mounted) await _load();
            }
          : null,
      onRead: _doors.canRead(entry)
          ? () async {
              await _doors.readFromRow(context, entry);
              if (mounted) await _load();
            }
          : null,
      menuBuilder: (_) => workMenuItems(_actions, entry,
          transcribed: _rowState.transcribed.contains(work.id), extras: [
        PopupMenuItem(
            key: Key('pin-${work.id}'),
            value: 'pin',
            child: Text(work.pinned ? 'Unpin' : 'Pin')),
        PopupMenuItem(
            key: Key('remove-${work.id}'),
            value: 'remove',
            child: Text(episode == null ? 'Remove' : 'Remove from Library')),
      ]),
      onMenu: (v) async {
        switch (v) {
          case 'pin':
            await _togglePin(e);
          case 'remove':
            _remove(e);
          default:
            await _actions.handleShared(context, v, entry,
                showTitle: e.feedTitle);
            if (mounted) await _load();
        }
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onPaste;
  final VoidCallback onEpub;
  final VoidCallback onWeb;
  final VoidCallback onGutenberg;
  final VoidCallback? onAudiobook;
  const _EmptyState(
      {required this.onPaste,
      required this.onEpub,
      required this.onWeb,
      required this.onGutenberg,
      this.onAudiobook});

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
              Icon(Icons.eco_outlined,
                  size: 56, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text('Nothing on the trellis yet.',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text('Bring something you would like to read.',
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton.icon(
                  onPressed: onPaste,
                  icon: const Icon(Icons.content_paste),
                  label: const Text('Paste text')),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                  onPressed: onEpub,
                  icon: const Icon(Icons.menu_book_outlined),
                  label: const Text('Import an EPUB')),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                  onPressed: onWeb,
                  icon: const Icon(Icons.public),
                  label: const Text('From the web')),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                  onPressed: onGutenberg,
                  icon: const Icon(Icons.local_library_outlined),
                  label: const Text('Project Gutenberg')),
              if (onAudiobook != null) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                    onPressed: onAudiobook,
                    icon: const Icon(Icons.headphones_outlined),
                    label: const Text('Audiobook (pick files)')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
