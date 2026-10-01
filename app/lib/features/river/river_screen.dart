import 'dart:async';

import 'package:flutter/material.dart';
import 'package:openhearth_design/openhearth_design.dart';

import '../../db/database.dart' hide Alignment;
import '../settings/theme_preference.dart';
import '../dsp/dsp_coordinator.dart';
import '../episodes/episode_actions.dart';
import '../episodes/episode_row.dart';
import '../episodes/episode_selection.dart';
import '../feeds/episode_download_coordinator.dart';
import '../jobs/jobs_screen.dart' show downloadFraction, downloadStatus;
import '../feeds/feeds_repository.dart';
import '../feeds/feeds_screen.dart';
import '../feeds/subscribe_screen.dart';
import '../models/consent.dart';
import '../models/format.dart';
import '../models/models_screen.dart' show modelLabel;
import '../player/player_controller.dart';
import '../../services/device_services.dart' show TtsSpeaker;
import '../reader/reader_doors.dart';
import '../reader/reader_screen.dart';
import '../reader/speech/speech_engine.dart';
import '../search/search_entry.dart';
import '../search/search_screen.dart';
import '../reader/speech/speech_temp_files.dart';
import '../reader/translation/marian_engine.dart';
import '../transcribe/job_cards.dart';
import '../transcribe/transcribe_coordinator.dart';
import 'river_triage.dart';
import '../shared/capped_body.dart';

/// The River (ADR-0003 law 1): ONE reverse-chronological list across every
/// feed. The order comes from the DAO's single query and is never touched
/// here — the chips FILTER, they do not sort; no ranking code path exists.
/// It is a permanent archive (ADR-0019), so it is read a page at a time.
class RiverScreen extends StatefulWidget {
  final AppDatabase db;
  final Profile profile;
  final FeedsRepository repository;
  final PlayerController playerController;
  final TranscribeCoordinator coordinator;

  /// The standalone "Download" door (Campaign 6) — onto disk without
  /// requesting a transcript. Gated the same way transcribe already is:
  /// [localMlAvailable] false means this is never even constructed against
  /// a real filesystem, so it's never touched.
  final EpisodeDownloadCoordinator? downloadCoordinator;

  /// The offline DSP preprocess (Campaign 6, ADR-0012) — triggered
  /// automatically right after a successful Download, never on its own
  /// door: "processed on download" is the whole feature's promise, not a
  /// separate manual action. Null on the web tier, same law as
  /// [downloadCoordinator].
  final DspCoordinator? dspCoordinator;

  /// Opens the Jobs screen; null hides the menu item.
  final VoidCallback? onOpenJobs;

  /// DeviceServices.localMlAvailable, handed down by the shell. Where
  /// false (the web tier) the transcribe AND download menu items are
  /// simply not offered — play still works; the UI never offers what
  /// must fail (dart:io's File throws on any real op under dart2js).
  final bool localMlAvailable;

  /// Resolves the neural voice for a work's language (ADR-0006) — the
  /// shell closes over `DeviceServices.resolveSpeechEngine`; null keeps
  /// every reader this screen opens on the system voice.
  final Future<SynthesisSpeechEngine?> Function({String? lang})?
  resolveSpeechEngine;

  /// See `LibraryScreen.lookupDefinition`.
  final Future<String?> Function(String word)? lookupDefinition;

  /// See `LibraryScreen.createSpeechTempFiles`.
  final SpeechTempFiles Function()? createSpeechTempFiles;

  /// Resolves a translator for a specific (source, target) pair (Campaign
  /// 8 "Babel widens" Phase 1, generalizing ADR-0008 "Babel" Phase 3) —
  /// see `LibraryScreen.resolveTranslator`.
  final Future<MarianTranslator?> Function(
      {required String sourceLang, required String targetLang})?
      resolveTranslator;

  /// See `LibraryScreen.availableTranslationTargets`.
  final Future<List<String>> Function({required String sourceLang})?
      availableTranslationTargets;

  /// The speak-mode voice, only for books the Subscriptions page opens;
  /// see `LibraryScreen.tts`.
  final TtsSpeaker? tts;

  /// Whether this is the tab on screen. The shell keeps Latest mounted
  /// under the other tabs; coming back re-reads what is loaded, in place.
  final bool active;

  const RiverScreen(
      {super.key,
      this.active = true,
      required this.db,
      required this.profile,
      required this.repository,
      required this.playerController,
      required this.coordinator,
      this.downloadCoordinator,
      this.dspCoordinator,
      this.onOpenJobs,
      this.localMlAvailable = true,
      this.resolveSpeechEngine,
      this.lookupDefinition,
      this.createSpeechTempFiles,
      this.resolveTranslator,
      this.availableTranslationTargets,
      this.tts});

  @override
  State<RiverScreen> createState() => _RiverScreenState();
}

enum _RiverFilter { all, text, audio }

class _RiverScreenState extends State<RiverScreen>
    with WidgetsBindingObserver {
  List<RiverEntry>? _entries;

  /// Whether the last page came back full, so another may follow.
  bool _hasMore = false;
  bool _loadingMore = false;

  /// The last page below failed to load: the footer offers a retry
  /// instead of a spinner nothing will ever answer.
  bool _moreFailed = false;

  /// When this reader's previous visit began; rows published after it
  /// sit above the "new since" line. A visit is an app session: the time
  /// is read and replaced on a cold start (this screen's mount) and on
  /// each return to the app, never on a tab switch, so the line holds
  /// still while the listener moves between tabs, and an app kill
  /// mid-visit loses nothing.
  int? _lastVisitMs;

  /// Bumped by every load that replaces the list, so a page still in
  /// flight from before a filter change or refresh is dropped on arrival.
  int _generation = 0;

  _RiverFilter _filter = _RiverFilter.all;
  late final RiverTriage _triage = RiverTriage(widget.db);
  late final EpisodeActions _actions = EpisodeActions(
    db: widget.db,
    profileId: widget.profile.id,
    player: widget.playerController,
    downloader: widget.downloadCoordinator,
    dsp: widget.dspCoordinator,
    services: widget.repository.services,
    localMlAvailable: widget.localMlAvailable,
  );
  EpisodeListState _rowState = EpisodeListState.empty;
  final _selection = EpisodeSelection();
  final _undo = OhUndoController();
  late final EpisodeBulk _bulk =
      EpisodeBulk(actions: _actions, selection: _selection, undo: _undo);

  @override
  void initState() {
    super.initState();
    _selection.reload = _reloadLoaded;
    _selection.addListener(_onSelection);
    WidgetsBinding.instance.addObserver(this);
    _load();
    _markVisit();
  }

  /// Whether the app went to the background since the visit began. A
  /// resume from mere `inactive` (the notification shade, a system
  /// dialog) is not a new visit, and must not wipe the line.
  bool _backgrounded = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _backgrounded = true;
    }
    if (state != AppLifecycleState.resumed) return;
    if (_backgrounded) {
      _backgrounded = false;
      _markVisit();
    }
    // A background check may have brought items while the app was away.
    _reloadLoaded();
  }

  @override
  void didUpdateWidget(RiverScreen old) {
    super.didUpdateWidget(old);
    // Back from another tab, where any loaded row may have changed (kept,
    // played, queued); the re-read keeps the list's length, so its place.
    if (widget.active && !old.active) _reloadLoaded();
  }

  Future<void> _markVisit() async {
    final previous = await widget.db.profilesDao.swapLatestSeen(
        widget.profile.id,
        nowMs: DateTime.now().millisecondsSinceEpoch);
    if (!mounted || previous == null) return;
    setState(() => _lastVisitMs = previous);
  }

  /// Whether the "new since" line goes above row [i]: the first row
  /// published before the last visit, below at least one published after.
  /// Publish time falls back to first-seen when a feed gives no date.
  bool _newLineAbove(List<RiverEntry> visible, int i) {
    final since = _lastVisitMs;
    return since != null &&
        i > 0 &&
        visible[i - 1].episode.publishedAtMs > since &&
        visible[i].episode.publishedAtMs <= since;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _selection.removeListener(_onSelection);
    _selection.dispose();
    _undo.dispose();
    super.dispose();
  }

  void _onSelection() => setState(() {});

  /// A filter change keeps only the selected rows still on screen, so a
  /// bulk action never reaches rows the listener can't see.
  void _setFilter(_RiverFilter filter) {
    setState(() => _filter = filter);
    _load();
  }

  RiverKind get _kind => switch (_filter) {
        _RiverFilter.all => RiverKind.all,
        _RiverFilter.text => RiverKind.text,
        _RiverFilter.audio => RiverKind.audio,
      };

  /// Whether "Mark everything older as played" has anything to reach.
  /// Older means published strictly earlier: the podcast page's rule, so
  /// a tie is never swept up because of where the list placed it. Past
  /// the loaded pages the answer waits for the tap.
  bool _offersOlder(List<RiverEntry> visible, RiverEntry e) =>
      _hasMore ||
      unplayedAudio(_entriesOf([
        for (final o in visible)
          if (o.episode.publishedAtMs < e.episode.publishedAtMs) o,
      ])).isNotEmpty;

  Future<void> _markOlderPlayed(RiverEntry e) async {
    final older = await widget.db.feedsDao.olderUnplayedAudio(
        widget.profile.id,
        publishedBeforeMs: e.episode.publishedAtMs);
    if (!mounted) return;
    if (older.isEmpty) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(
            persist: false, content: Text('Nothing older to mark.')));
      return;
    }
    await _bulk.markOlderPlayed(context, older);
  }

  static List<EpisodeEntry> _entriesOf(List<RiverEntry> rows) =>
      [for (final e in rows) (work: e.work, episode: e.episode)];

  static RiverCursor _cursorOf(RiverEntry e) =>
      (publishedAtMs: e.episode.publishedAtMs, workId: e.work.id);

  /// The first page, from the top: on open, on a filter change and after
  /// a refresh brings new items.
  Future<void> _load() async {
    final generation = ++_generation;
    final entries = await widget.db.feedsDao
        .riverItems(widget.profile.id, kind: _kind);
    final rowState =
        await EpisodeListState.load(widget.db, widget.profile.id);
    if (!mounted || generation != _generation) return;
    _actions.forgetArtwork();
    setState(() {
      _entries = entries;
      _hasMore = entries.length == riverPageSize;
      _moreFailed = false;
      _rowState = rowState;
    });
  }

  /// Re-reads every loaded row, and anything newer, but no further: after
  /// a bulk change or a return from another screen, where any loaded row
  /// may have changed. The list keeps its length, so the scroll keeps
  /// its place.
  Future<void> _reloadLoaded() async {
    final loaded = _entries;
    if (loaded == null || loaded.isEmpty) return _load();
    final generation = ++_generation;
    final entries = await widget.db.feedsDao.riverItems(widget.profile.id,
        kind: _kind, through: _cursorOf(loaded.last), limit: null);
    final rowState =
        await EpisodeListState.load(widget.db, widget.profile.id);
    if (!mounted || generation != _generation) return;
    _actions.forgetArtwork();
    setState(() {
      _entries = entries;
      _rowState = rowState;
      _moreFailed = false;
    });
  }

  /// The next page below the last loaded row.
  Future<void> _loadMore() async {
    final loaded = _entries;
    if (_loadingMore ||
        _moreFailed ||
        !_hasMore ||
        loaded == null ||
        loaded.isEmpty) {
      return;
    }
    _loadingMore = true;
    final generation = _generation;
    List<RiverEntry>? page;
    try {
      page = await widget.db.feedsDao.riverItems(widget.profile.id,
          kind: _kind, after: _cursorOf(loaded.last));
    } catch (e) {
      debugPrint('Latest: loading the next page failed: $e');
    } finally {
      _loadingMore = false;
    }
    if (!mounted) return;
    if (generation != _generation) {
      // A reload replaced the list while this page was in flight. Its
      // footer asked meanwhile and was turned away, so ask again for it,
      // below the new list's last row.
      unawaited(_loadMore());
      return;
    }
    if (page == null) {
      setState(() => _moreFailed = true);
      return;
    }
    final got = page;
    setState(() {
      _entries = [...loaded, ...got];
      _hasMore = got.length == riverPageSize;
    });
  }

  /// Re-reads one row after an action on it, in place.
  Future<void> _patch(int workId) async {
    final entry = await widget.db.feedsDao.riverEntryOf(workId);
    final rowState =
        await EpisodeListState.load(widget.db, widget.profile.id);
    if (!mounted) return;
    setState(() {
      _rowState = rowState;
      final entries = _entries;
      if (entries == null) return;
      _entries = [
        for (final e in entries)
          if (e.work.id != workId) e else ?entry,
      ];
    });
  }

  Future<void> _refresh() async {
    await widget.repository.refreshAll(widget.profile.id);
    await _load();
  }

  Future<void> _followFeed() async {
    final followed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SubscribeScreen(
          repository: widget.repository,
          profileId: widget.profile.id,
        ),
      ),
    );
    if (followed == true) await _reloadLoaded();
  }

  ReaderDoors get _readerDoors => ReaderDoors(
      tts: widget.tts,
      localMlAvailable: widget.localMlAvailable,
      resolveSpeechEngine: widget.resolveSpeechEngine,
      lookupDefinition: widget.lookupDefinition,
      createSpeechTempFiles: widget.createSpeechTempFiles,
      player: widget.playerController,
      resolveTranslator: widget.resolveTranslator,
      availableTranslationTargets: widget.availableTranslationTargets);

  SearchDoors get _searchDoors => SearchDoors(
      db: widget.db,
      profile: widget.profile,
      actions: _actions,
      readerDoors: _readerDoors);

  Future<void> _manageFeeds() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => FeedsScreen(
          db: widget.db,
          repository: widget.repository,
          profile: widget.profile,
          localMlAvailable: widget.localMlAvailable,
          playerController: widget.playerController,
          downloadCoordinator: widget.downloadCoordinator,
          dspCoordinator: widget.dspCoordinator,
          readerDoors: _readerDoors,
        ),
      ),
    );
    await _reloadLoaded();
  }

  Future<void> _openSearch() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => SearchScreen(doors: _searchDoors)));
    await _reloadLoaded();
  }


  Future<void> _openItem(RiverEntry e) async {
    await widget.db.feedsDao.markRead(
      e.work.id,
      DateTime.now().millisecondsSinceEpoch,
    );
    if (!mounted) return;
    // See LibraryScreen._open — same resolve-before-push shape (ADR-0006).
    final resolver = widget.resolveSpeechEngine;
    final hasVoice = resolver == null
        ? false
        : await resolver(lang: e.work.lang) != null;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReaderScreen(
          db: widget.db,
          profileId: widget.profile.id,
          work: e.work,
          offerNeuralVoice: widget.localMlAvailable && !hasVoice,
          resolveSpeechEngine: widget.resolveSpeechEngine,
          lookupDefinition: widget.lookupDefinition,
          createSpeechTempFiles: widget.createSpeechTempFiles,
          player: widget.playerController,
          resolveTranslator: widget.resolveTranslator,
          availableTranslationTargets: widget.availableTranslationTargets),
    ));
    await _patch(e.work.id);
  }

  Future<void> _playItem(RiverEntry e) async {
    await widget.playerController.playWork(e.work);
    await _patch(e.work.id); // the unread dot cleared
  }

  /// The transcribe entry: plan → the ONE consent chokepoint when anything
  /// would download (ADR-0003 law 6) → hand the flow to the coordinator.
  Future<void> _transcribe(RiverEntry e, {required bool translate}) async {
    final url = e.episode.enclosureUrl;
    if (url == null) return;
    final coordinator = widget.coordinator;
    final plan = await coordinator.planFor(
      workId: e.work.id,
      enclosureUrl: url,
    );
    if (!mounted) return;
    if (plan.needsDownloads) {
      final ok = await confirmDownload(
        context,
        items: [
          if (plan.needsModel)
            DownloadItem(
              '${modelLabel(plan.model.id)} '
              '(${formatBytes(plan.model.sizeBytes)}), one time',
            ),
          if (plan.needsAudio)
            DownloadItem('This episode’s audio (size depends on the episode)'),
        ],
      );
      if (!ok) return;
    }
    unawaited(
      coordinator.start(
        workId: e.work.id,
        title: e.work.title,
        enclosureUrl: url,
        lang: e.work.lang,
        translate: translate,
      ),
    );
  }

  /// The shared menu entries (queue, download, mark played) live with
  /// [EpisodeActions]; the row shows their result after a reload.
  Future<void> _common(String choice, RiverEntry e) async {
    await _actions.handleCommon(
        context, choice, (work: e.work, episode: e.episode));
    await _patch(e.work.id);
  }

  /// Keep: into the library, out of the unread flow. Undo restores the
  /// exact prior state (Peckish's verbatim-restore idiom) — no new "Kept"
  /// filter exists anywhere in the river (ADR-0011): kept things live in
  /// the library, full stop.
  Future<void> _keep(RiverEntry e) async {
    final prior = _triage.priorStateOf(
        persistence: e.work.persistence, readAtMs: e.episode.readAtMs);
    await _triage.keep(e.work.id, nowMs: DateTime.now().millisecondsSinceEpoch);
    await _patch(e.work.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: const Text('Kept. It’s in your library now.'),
        // A triage Undo is a convenience (nothing is deleted); the line
        // lapses rather than trailing across screens (conformance C14).
        persist: false,
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => _undoTriage(e.work.id, prior),
        ),
      ));
  }

  /// Let it pass: the explicit "I saw this, no thanks" — marks read,
  /// promotes nothing, and the item stays in the archive (ADR-0019).
  Future<void> _letItPass(RiverEntry e) async {
    final prior = _triage.priorStateOf(
        persistence: e.work.persistence, readAtMs: e.episode.readAtMs);
    await _triage.letItPass(e.work.id,
        nowMs: DateTime.now().millisecondsSinceEpoch);
    await _patch(e.work.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: const Text('Marked read'),
        // A triage Undo is a convenience (nothing is deleted); the line
        // lapses rather than trailing across screens (conformance C14).
        persist: false,
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => _undoTriage(e.work.id, prior),
        ),
      ));
  }

  Future<void> _undoTriage(int workId, TriagePriorState prior) async {
    await _triage.undo(workId, prior);
    await _patch(workId);
  }

  /// The chips filter in the query now, so what is loaded is what shows.
  List<RiverEntry> get _visible => _entries ?? const [];

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    final theme = ThemePreferenceScope.maybeOf(context);
    return Scaffold(
      bottomSheet: OhUndoBar(controller: _undo),
      appBar: _selection.active ? _bulk.bar(context) : AppBar(
        title: const Text('Latest'),
        actions: [
          OhBarActions(children: [
            OhBarAction(
              key: const Key('manage-feeds'),
              icon: Icons.rss_feed,
              // The industry's word for the shows you follow, and the
              // title of the screen it opens.
              label: 'Subscriptions',
              onPressed: _manageFeeds,
            ),
            OhBarOverflow<String>(
              key: const Key('river-more'),
              onSelected: (choice) => switch (choice) {
                'jobs' => widget.onOpenJobs?.call(),
                final v when isThemeMenuValue(v) =>
                  chooseThemeFromMenu(theme!, v),
                _ => _selection.enter(),
              },
              itemBuilder: (_) => [
                if (_entries?.isNotEmpty ?? false)
                  const PopupMenuItem(
                    key: Key('river-select'),
                    value: 'select',
                    child: Text('Select'),
                  ),
                if (widget.onOpenJobs != null)
                  const PopupMenuItem(
                    key: Key('river-open-jobs'),
                    value: 'jobs',
                    child: Text('Jobs'),
                  ),
                if (theme != null) ...themeMenuItems(theme),
              ],
            ),
          ]),
        ],
      ),
      body: CappedBody(child: _bulk.scope(child: switch (entries) {
        null => const Center(child: CircularProgressIndicator()),
        [] => Column(
          children: [
            SearchEntry(
                key: const Key('river-search'), onPressed: _openSearch),
            TranscribeJobCards(coordinator: widget.coordinator),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _refresh,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 48),
                      child: _EmptyRiver(onFollow: _followFeed),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        _ => _riverList(),
      })),
    );
  }

  Widget _riverList() {
    // Once per build: the filter rebuilds a list of every item, and the
    // builder used to ask for it again for every row it laid out.
    final visible = _visible;
    _selection.universe = _entriesOf(visible);
    return Column(
      children: [
        SearchEntry(
            key: const Key('river-search'), onPressed: _openSearch),
        TranscribeJobCards(coordinator: widget.coordinator),
        _filterChips(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: visible.length + (_hasMore ? 1 : 0),
              itemBuilder: (_, i) => i < visible.length
                  ? (_newLineAbove(visible, i)
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const _NewSinceLine(),
                            _itemTile(visible, i),
                          ],
                        )
                      : _itemTile(visible, i))
                  // A new list or a longer one is a new slot, so it asks
                  // again once it is built.
                  : _moreFailed
                      ? _MoreFailed(
                          onRetry: () => setState(() => _moreFailed = false))
                      : _MoreBelow(
                          key: ValueKey((_generation, visible.length)),
                          onShown: _loadMore),
            ),
          ),
        ),
      ],
    );
  }

  Widget _filterChips() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          ChoiceChip(
            key: const Key('chip-all'),
            label: const Text('All'),
            selected: _filter == _RiverFilter.all,
            onSelected: (_) => _setFilter(_RiverFilter.all),
          ),
          const SizedBox(width: 8),
          ChoiceChip(
            key: const Key('chip-text'),
            label: const Text('Text'),
            selected: _filter == _RiverFilter.text,
            onSelected: (_) => _setFilter(_RiverFilter.text),
          ),
          const SizedBox(width: 8),
          ChoiceChip(
            key: const Key('chip-audio'),
            label: const Text('Audio'),
            selected: _filter == _RiverFilter.audio,
            onSelected: (_) => _setFilter(_RiverFilter.audio),
          ),
        ],
      ),
    );
  }

  Widget _itemTile(List<RiverEntry> visible, int index) {
    final e = visible[index];
    final theme = Theme.of(context);
    final selecting = _selection.active;
    final isAudio = e.episode.enclosureUrl != null;
    final entry = (work: e.work, episode: e.episode);
    final row = EpisodeRow(
      work: e.work,
      episode: e.episode,
      facts: EpisodeRowFacts.of(e.episode, _rowState,
          downloaded: isAudio && _actions.isDownloaded(e.episode)),
      showTitle: e.feedTitle,
      artwork: _actions.artworkFor(e.episode),
      onTap: selecting
          ? () => _selection.toggle(e.work.id)
          : () => _openItem(e),
      onPlay: isAudio ? () => _playItem(e) : null,
      onRead: _readerDoors.canOpenTranscript
          ? () async {
              await _readerDoors.openTranscript(context,
                  db: widget.db, work: e.work);
              await _patch(e.work.id);
            }
          : null,
      selected: selecting ? _selection.contains(e.work.id) : null,
      onLongPress: selecting
          ? () => _selection.toggle(e.work.id)
          : () => _selection.enter(e.work.id),
      below: [
        if (isAudio && widget.downloadCoordinator != null)
          _RowDownload(
              coordinator: widget.downloadCoordinator!, workId: e.work.id),
      ],
      // Overflow parity (ergonomic-ux): every row gets the menu, audio or
      // not — swipe is the fast path, the menu is the reachable-by-anyone
      // path, and Keep/Let it pass live in both.
      onMenu: (choice) => switch (choice) {
        'keep' => _keep(e),
        'pass' => _letItPass(e),
        'transcribe' => _transcribe(e, translate: false),
        'translate' => _transcribe(e, translate: true),
        'mark-older' => _markOlderPlayed(e),
        _ => _common(choice, e),
      },
      menuBuilder: (_) => [
        PopupMenuItem(
            key: Key('keep-${e.work.id}'),
            value: 'keep',
            child: const Text('Keep')),
        PopupMenuItem(
            key: Key('pass-${e.work.id}'),
            value: 'pass',
            child: const Text('Let it pass')),
        ..._actions.commonMenuItems(entry),
        if (isAudio && _offersOlder(visible, e))
          PopupMenuItem(
              key: Key('mark-older-${e.work.id}'),
              value: 'mark-older',
              child: const Text('Mark everything older as played')),
        if (isAudio && widget.localMlAvailable) ...[
          PopupMenuItem(
              key: Key('transcribe-${e.work.id}'),
              value: 'transcribe',
              child: Text(e.episode.archivedAtMs != null
                  ? 'Re-download audio'
                  : 'Transcribe')),
          PopupMenuItem(
              key: Key('translate-${e.work.id}'),
              value: 'translate',
              child: const Text('Transcribe + translate to English')),
        ],
      ],
    );
    // Swipe Keep / Let it pass (Campaign 5): confirmDismiss performs the
    // gesture then always returns false, so the tile springs back showing
    // its new state — the house idiom (archived rows dim rather than
    // vanish) applied to triage too. Nothing is ever removed from the
    // river by a swipe; only tap-to-open already changes what's visible
    // here, and only via the unread dot.
    return Dismissible(
      key: Key('swipe-${e.work.id}'),
      // A swipe while selecting would Keep or Let pass one row behind the
      // listener's back.
      direction:
          selecting ? DismissDirection.none : DismissDirection.horizontal,
      background: Container(
        color: theme.colorScheme.primaryContainer,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: const Icon(Icons.bookmark_add_outlined),
      ),
      secondaryBackground: Container(
        color: theme.colorScheme.surfaceContainerHighest,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: const Icon(Icons.done),
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          await _keep(e);
        } else {
          await _letItPass(e);
        }
        return false;
      },
      child: row,
    );
  }

}

/// The quiet line between what arrived since the last visit and what was
/// already there. Words only: no count, no colour that asks for action.
class _NewSinceLine extends StatelessWidget {
  const _NewSinceLine();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Padding(
        key: const Key('latest-new-since'),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(
          children: [
            const Expanded(child: Divider()),
            Flexible(
              flex: 3,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text('New since you last looked',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
            ),
            const Expanded(child: Divider()),
          ],
        ),
      ),
    );
  }
}

/// The list's last slot while more pages exist: built as it nears the
/// screen (the list's cache extent), which is the cue to fetch the next.
class _MoreBelow extends StatefulWidget {
  final VoidCallback onShown;
  const _MoreBelow({super.key, required this.onShown});

  @override
  State<_MoreBelow> createState() => _MoreBelowState();
}

class _MoreBelowState extends State<_MoreBelow> {
  @override
  void initState() {
    super.initState();
    // Not during build: the fetch ends in setState on the list.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onShown();
    });
  }

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
}

/// The footer after a page below failed: says so, and offers the one
/// verb that helps. Retrying swaps the spinner footer back in, which asks
/// again as soon as it is built.
class _MoreFailed extends StatelessWidget {
  final VoidCallback onRetry;
  const _MoreFailed({required this.onRetry});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Couldn’t load older items.'),
            const SizedBox(height: 8),
            OutlinedButton(
              key: const Key('river-more-retry'),
              onPressed: onRetry,
              child: const Text('Try again'),
            ),
          ],
        ),
      );
}

/// The row's own honest download line: bytes while it runs, "paused" or
/// the reason after it stops, beside the one verb that helps. Listens
/// per row so a progress beat rebuilds one row, not the whole list.
class _RowDownload extends StatelessWidget {
  final EpisodeDownloadCoordinator coordinator;
  final int workId;
  const _RowDownload({required this.coordinator, required this.workId});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: coordinator,
      builder: (context, _) {
        if (!coordinator.entries.any((e) => e.workId == workId)) {
          return const SizedBox.shrink();
        }
        final s = coordinator.stateOf(workId);
        final theme = Theme.of(context);
        return Padding(
          key: Key('row-download-$workId'),
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      downloadStatus(s),
                      style: theme.textTheme.bodySmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (s.downloading)
                    TextButton(
                      key: Key('row-download-pause-$workId'),
                      onPressed: () => coordinator.cancel(workId),
                      child: const Text('Pause'),
                    )
                  else
                    TextButton(
                      key: Key('row-download-resume-$workId'),
                      onPressed: () => coordinator.resume(workId),
                      child: Text(s.failed ? 'Try again' : 'Resume'),
                    ),
                ],
              ),
              if (s.downloading)
                LinearProgressIndicator(value: downloadFraction(s)),
            ],
          ),
        );
      },
    );
  }
}

class _EmptyRiver extends StatelessWidget {
  final VoidCallback onFollow;
  const _EmptyRiver({required this.onFollow});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                Icons.dynamic_feed_outlined,
                size: 56,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                'Nothing in Latest yet.',
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                // The archive promise in the same breath as the no-ranking
                // one (ADR-0019): nothing here ever leaves on its own.
                'Add a podcast or a site’s feed, and its new episodes and '
                'articles arrive here, newest first, never ranked, and stay. '
                'What you follow is under Subscriptions, at the top.',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: onFollow,
                icon: const Icon(Icons.rss_feed),
                label: const Text('Follow a feed'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
