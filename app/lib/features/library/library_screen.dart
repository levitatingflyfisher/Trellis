import 'dart:async';
import 'dart:convert';

import 'package:comms_core/comms_core.dart';
import 'package:flutter/material.dart';
import 'package:intake_core/intake_core.dart' show EpubTooLargeException;
import 'package:openhearth_design/openhearth_design.dart';

import '../../db/database.dart' hide Alignment;
import '../../net/io_fetcher.dart';
import '../../services/device_services.dart';
import '../intake/document_intake.dart';
import '../intake/pdf_reader.dart' show PdfUnreadableException;
import '../intake/gutenberg_screen.dart';
import '../intake/paste_intake.dart';
import '../intake/url_intake.dart';
import '../player/player_controller.dart';
import '../reader/reader_doors.dart';
import '../reader/speech/speech_engine.dart';
import '../reader/speech/speech_temp_files.dart';
import '../reader/translation/translation_service.dart';
import '../episodes/episode_actions.dart';
import '../works/work_menu.dart';
import '../works/work_open.dart';
import '../works/remove_undo.dart';
import '../works/work_row.dart';
import '../search/search_entry.dart';
import '../search/search_screen.dart';
import 'library_filter_screen.dart';
import 'library_filter_sheet.dart';
import 'library_query.dart';
import '../shared/capped_body.dart';
import '../shared/purpose_line.dart';

typedef _Entry = ({Work work, Episode? episode, String? feedTitle});

/// Trellis opens files you already have; it does nothing about locks.
const copyProtectionNote =
    'Trellis discourages using tools that strip copy protection in '
    'violation of the DMCA, such as Calibre’s DeDRM or Libation.';

/// One reader's works: pinned first, then newest, each in the shared row
/// every list of works uses; progress is the cursor law's numerator over
/// the segment count. The empty state is an invitation,
/// not a void (ADR-0003 — no guilt, no streaks).
class LibraryScreen extends StatefulWidget {
  final AppDatabase db;
  final Profile profile;

  /// The + Add sheet's "Subscribe to a feed": the shell's subscribe
  /// screen, opened from this tab. Null hides the entry.
  final Future<void> Function(BuildContext)? onSubscribe;

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
      this.onSubscribe,
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

  /// The kind chip picked (null: All). Apart from [_activeQuery], the
  /// Filter sheet's read state, pin and show: a chip is one tap, in
  /// sight, and the bar's Clear filter leaves it be.
  LibraryItemType? _kind;

  void _setQuery(LibraryQuery? q) =>
      setState(() => _activeQuery = q == null || q.isEmpty ? null : q);

  /// What the list shows: the chip and the sheet together.
  LibraryQuery get _effectiveQuery => LibraryQuery(
      types: {?_kind},
      feedId: _activeQuery?.feedId,
      readState: _activeQuery?.readState ?? ReadState.any,
      pinned: _activeQuery?.pinned);

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
    final query = _effectiveQuery;
    if (query.isEmpty) return entries;
    return [
      for (final e in entries)
        if (matchesLibraryQuery(
            (work: e.work, episode: e.episode, feedTitle: e.feedTitle), query))
          e
    ];
  }

  /// The kinds this Library holds, in the chips' order: a chip that could
  /// only ever show nothing is not offered.
  List<LibraryItemType> get _kindsHeld {
    final held = {
      for (final e in _liveEntries ?? const <_Entry>[])
        ?libraryKindOf(e.work, e.episode),
    };
    return [
      for (final k in LibraryItemType.values)
        if (held.contains(k)) k,
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
                currentQuery: _effectiveQuery)));
    if (!mounted) return;
    if (result != null) _applyQuery(result);
    await _load(); // a view may have been created/deleted/reordered too
  }

  void _applySavedView(SavedViewRow v) => _applyQuery(LibraryQuery.fromJson(
      jsonDecode(v.queryJson) as Map<String, Object?>));

  /// A whole query (a saved view): its one kind to the chips, the rest to
  /// the sheet's filter.
  void _applyQuery(LibraryQuery query) {
    setState(() =>
        _kind = query.types.length == 1 ? query.types.single : null);
    _setQuery(LibraryQuery(
        feedId: query.feedId,
        readState: query.readState,
        pinned: query.pinned));
  }

  Future<void> _pasteText() async {
    final workId = await showPasteIntakeDialog(context,
        db: widget.db, profileId: widget.profile.id);
    if (workId != null) await _load();
  }

  Future<void> _importFile() async {
    try {
      final workId = await pickAndImportDocument(
          db: widget.db, profileId: widget.profile.id);
      if (workId != null) await _load();
    } on EpubTooLargeException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } on PdfUnreadableException catch (e) {
      // Its own words: a locked file, or one that is pictures of pages.
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } on FormatException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That file couldn’t be read.')));
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

  Future<void> _subscribe() async {
    final onSubscribe = widget.onSubscribe;
    if (onSubscribe != null) await onSubscribe(context);
  }

  /// Every way in, in one sheet (1.5.8): a feed, a file, pasted text, a
  /// link. Over the app's Navigator, so it covers the bars like any sheet
  /// rather than leaving the tabs live beneath it.
  void _addSheet() {
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      // As tall as its entries need, and scrolling where the screen is
      // shorter than that (a small phone, large text).
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(
            child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.onSubscribe != null)
              ListTile(
                leading: const Icon(Icons.rss_feed),
                title: const Text('Subscribe to a feed'),
                onTap: () {
                  Navigator.pop(sheet);
                  _subscribe();
                },
              ),
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
              title: const Text('Import a file'),
              subtitle: const Text(importableKindsWords),
              onTap: () {
                Navigator.pop(sheet);
                _importFile();
              },
            ),
            ListTile(
              leading: const Icon(Icons.public),
              title: const Text('Open a link'),
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
            // The owner's words (28 Oct), small and at the foot: not a
            // banner. Names two tools for clarity, and no link on purpose.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Text(
                copyProtectionNote,
                key: const Key('add-copy-protection-note'),
                style: Theme.of(sheet).textTheme.bodySmall?.copyWith(
                    color: Theme.of(sheet).colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        )),
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        // Icon + word for what matters here (fleet ruling on top bars).
        actions: [
          OhBarActions(children: [
            OhBarAction(
              key: const Key('open-filter'),
              icon: hasFilter ? Icons.filter_alt_off : Icons.filter_alt_outlined,
              label: hasFilter ? 'Clear filter' : 'Filter',
              onPressed: _openFilter,
            ),
            // No ⋮: the Library has no rare actions of its own, and
            // app-wide things are in Settings (board-0131).
          ]),
        ],
      ),
      floatingActionButton: (entries == null || entries.isEmpty)
          ? null
          : FloatingActionButton.extended(
              key: const Key('library-add'),
              onPressed: _addSheet,
              icon: const Icon(Icons.add),
              label: const Text('Add')),
      body: CappedBody(
        child: switch (entries) {
          null => const Center(child: CircularProgressIndicator()),
          [] => _EmptyState(
              header: _purpose,
              onSubscribe: widget.onSubscribe != null ? _subscribe : null,
              onPaste: _pasteText,
              onFile: _importFile,
              onWeb: _fromWeb,
              onGutenberg: _fromGutenberg,
              onAudiobook:
                  widget.onImportAudiobook != null ? _importAudiobook : null),
          _ => _libraryList(_visibleEntries),
        },
      ),
    );
  }

  /// One plain line under the title (lead's ruling, 12 Nov): Latest is
  /// what arrives, the Library is what you keep.
  static const _purpose = PurposeLine(
      'What you keep: books, articles, texts, and episodes you kept or '
      'made.',
      textKey: Key('library-purpose'));

  /// What sits above the rows. It scrolls with them, so a short screen
  /// at large text still has room for the list.
  List<Widget> get _listHead => [
        _purpose,
        // Latest's own search bar and search screen, kept to the Library
        // (owner, 12 Nov).
        KeyedSubtree(
          key: const Key('library-search'),
          child: SearchEntry(onPressed: _openSearch),
        ),
        _kindChips(),
        if (_savedViews.isNotEmpty) _savedViewChips(),
      ];

  Future<void> _openSearch() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => SearchScreen(
            libraryOnly: true,
            doors: SearchDoors(
                db: widget.db,
                profile: widget.profile,
                actions: _actions,
                readerDoors: _readerDoors))));
    if (mounted) await _load();
  }

  /// The Library's own kinds (lead's ruling, 12 Nov), one tap each, only
  /// those it holds. They wrap rather than scroll sideways, so none sits
  /// off the edge of a narrow phone.
  Widget _kindChips() {
    final kinds = _kindsHeld;
    if (kinds.length < 2) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            ChoiceChip(
              key: const Key('library-kind-all'),
              label: const Text('All'),
              selected: _kind == null,
              onSelected: (_) => setState(() => _kind = null),
            ),
            for (final k in kinds)
              ChoiceChip(
                key: Key('library-kind-${k.name}'),
                label: Text(libraryKindLabel(k)),
                selected: _kind == k,
                onSelected: (_) => setState(() => _kind = k),
              ),
          ],
        ),
      ),
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
    final head = _listHead;
    // A real filter that matched nothing is a different state from an
    // empty library — the intake invitation would be misleading here.
    const nothing = Padding(
      padding: EdgeInsets.all(24),
      child: Text('Nothing matches this filter.', textAlign: TextAlign.center),
    );
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: head.length + (visible.isEmpty ? 1 : visible.length),
      itemBuilder: (_, i) => i < head.length
          ? head[i]
          : visible.isEmpty
              ? nothing
              : _workTile(visible[i - head.length]),
    );
  }

  Widget _workTile(_Entry e) {
    final work = e.work;
    final episode = e.episode;
    final entry = (work: work, episode: episode);
    final isAudio = episode?.enclosureUrl != null || work.kind == 'audiobook';
    return WorkRow(
      downloads: _actions.downloader,
      work: work,
      episode: episode,
      facts: WorkRowFacts.of(work, episode, _rowState,
          downloaded: episode != null && _actions.isDownloaded(episode)),
      showTitle: e.feedTitle,
      artwork: episode == null ? null : _actions.artworkFor(episode),
      onTap: () => _open(e),
      player: widget.player,
      second: _actions.listenButton(entry,
          feedLang: _rowState.feedLangs[episode?.feedId]),
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
          transcript: _rowState.transcriptOf(work.id),
          sourceLang: _rowState.sourceLangOf(entry), extras: [
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
  /// What sits under the title on every state of the Library.
  final Widget header;
  final VoidCallback? onSubscribe;
  final VoidCallback onPaste;
  final VoidCallback onFile;
  final VoidCallback onWeb;
  final VoidCallback onGutenberg;
  final VoidCallback? onAudiobook;
  const _EmptyState(
      {required this.header,
      this.onSubscribe,
      required this.onPaste,
      required this.onFile,
      required this.onWeb,
      required this.onGutenberg,
      this.onAudiobook});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      header,
      Expanded(child: _invitation(context)),
    ]);
  }

  Widget _invitation(BuildContext context) {
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
                  onPressed: onFile,
                  icon: const Icon(Icons.menu_book_outlined),
                  label: const Text('Import a file')),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                  onPressed: onWeb,
                  icon: const Icon(Icons.public),
                  label: const Text('Open a link')),
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
              if (onSubscribe != null) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                    onPressed: onSubscribe,
                    icon: const Icon(Icons.rss_feed),
                    label: const Text('Subscribe to a feed')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
