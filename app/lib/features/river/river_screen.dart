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
import '../intake/paste_intake.dart' show epochDayUtcNow;
import '../models/consent.dart';
import '../models/format.dart';
import '../models/models_screen.dart' show modelLabel;
import '../player/player_controller.dart';
import '../player/queue_screen.dart';
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
import 'river_decay.dart';
import 'river_triage.dart';
import '../shared/capped_body.dart';

/// The River (ADR-0003 law 1): ONE reverse-chronological list across every
/// feed. The order comes from the DAO's single query and is never touched
/// here — the chips FILTER, they do not sort; no ranking code path exists.
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

  const RiverScreen(
      {super.key,
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

class _RiverScreenState extends State<RiverScreen> {
  List<RiverEntry>? _entries;

  /// Ephemera the boot sweep decayed and nobody has restored or let go yet.
  int _decayed = 0;
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
    _selection.reload = _load;
    _selection.addListener(_onSelection);
    _load();
  }

  @override
  void dispose() {
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
    _selection.universe = _entriesOf(_visible);
  }

  /// Older means published strictly earlier, among the rows the filter
  /// shows: the podcast page's rule, so a tie is never swept up because
  /// of where the list happened to place it.
  static List<EpisodeEntry> _olderUnplayed(
          List<RiverEntry> visible, RiverEntry e) =>
      unplayedAudio(_entriesOf([
        for (final o in visible)
          if (o.episode.publishedAtMs < e.episode.publishedAtMs) o,
      ]));

  static List<EpisodeEntry> _entriesOf(List<RiverEntry> rows) =>
      [for (final e in rows) (work: e.work, episode: e.episode)];

  /// Queued or captured works: they do not decay (see heldWorkIds).
  Set<int> _held = const {};

  Future<void> _load() async {
    final entries = await widget.db.feedsDao.riverItems(widget.profile.id);
    final decayed = await widget.db.spineDao.decayedOf(widget.profile.id);
    final held = await widget.db.spineDao.heldWorkIds();
    final rowState =
        await EpisodeListState.load(widget.db, widget.profile.id);
    if (!mounted) return;
    _actions.forgetArtwork();
    setState(() {
      _entries = entries;
      _decayed = decayed.length;
      _held = held;
      _rowState = rowState;
    });
  }

  Future<void> _restoreDecayed() async {
    await widget.db.spineDao
        .restoreDecayed(widget.profile.id, todayEpochDay: epochDayUtcNow());
    await _load();
  }

  Future<void> _letDecayedGo() async {
    await widget.db.spineDao.purgeDecayed(widget.profile.id);
    await _load();
  }

  /// The boot sweep's one-line account (ADR-0003 law 2, made recoverable):
  /// what decayed, with Restore and Let go. It stays until the user picks
  /// one — never a snackbar that expires — and shows in the empty state
  /// too, since after a long absence the river is most likely empty.
  Widget _decayedNotice() {
    if (_decayed == 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      key: const Key('river-decayed-notice'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _decayed == 1
                ? '1 item older than 30 days left your Inbox. It’s kept 30 '
                    'more days, then deleted, unless you restore it.'
                : '$_decayed items older than 30 days left your Inbox. '
                    'They’re kept 30 more days, then deleted, unless you '
                    'restore them.',
            style: theme.textTheme.bodyMedium,
          ),
          OverflowBar(
            alignment: MainAxisAlignment.end,
            children: [
              TextButton(
                key: const Key('river-decayed-purge'),
                onPressed: _letDecayedGo,
                child: const Text('Let go'),
              ),
              TextButton(
                key: const Key('river-decayed-restore'),
                onPressed: _restoreDecayed,
                child: const Text('Restore'),
              ),
            ],
          ),
        ],
      ),
    );
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
    if (followed == true) await _load();
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
    await _load();
  }

  Future<void> _openSearch() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => SearchScreen(doors: _searchDoors)));
    await _load();
  }

  Future<void> _openHistory() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => HistoryScreen(doors: _searchDoors)));
    await _load();
  }

  /// Campaign 9 Phase 2: user: "hiding the queue as only accessible in
  /// the playing bar is odd." Play next/Play last already WRITE to the
  /// queue from every row's menu regardless of whether anything is
  /// playing — this is the same [QueueScreen] the mini bar's own door
  /// opens, just reachable without something already playing first.
  void _openQueue() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => QueueScreen(db: widget.db, profile: widget.profile),
      ),
    );
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
    await _load();
  }

  Future<void> _playItem(RiverEntry e) async {
    await widget.playerController.playWork(e.work);
    await _load(); // the unread dot cleared
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
    await _load();
  }

  /// Keep: into the library, out of the unread flow. Undo restores the
  /// exact prior state (Peckish's verbatim-restore idiom) — no new "Kept"
  /// filter exists anywhere in the river (ADR-0011): kept things live in
  /// the library, full stop.
  Future<void> _keep(RiverEntry e) async {
    final prior = _triage.priorStateOf(
        persistence: e.work.persistence, readAtMs: e.episode.readAtMs);
    await _triage.keep(e.work.id, nowMs: DateTime.now().millisecondsSinceEpoch);
    await _load();
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
  /// promotes nothing. Decay already handles aging; this is that law's
  /// explicit form.
  Future<void> _letItPass(RiverEntry e) async {
    final prior = _triage.priorStateOf(
        persistence: e.work.persistence, readAtMs: e.episode.readAtMs);
    await _triage.letItPass(e.work.id,
        nowMs: DateTime.now().millisecondsSinceEpoch);
    await _load();
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
    await _load();
  }

  List<RiverEntry> get _visible {
    final entries = _entries ?? const [];
    return switch (_filter) {
      _RiverFilter.all => entries,
      _RiverFilter.text => [
        for (final e in entries)
          if (e.episode.enclosureUrl == null) e,
      ],
      _RiverFilter.audio => [
        for (final e in entries)
          if (e.episode.enclosureUrl != null) e,
      ],
    };
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      bottomSheet: OhUndoBar(controller: _undo),
      appBar: _selection.active ? _bulk.bar(context) : AppBar(
        title: const Text('Inbox'),
        actions: [
          OhBarActions(children: [
            OhBarAction(
              key: const Key('manage-feeds'),
              icon: Icons.rss_feed,
              label: 'Feeds',
              onPressed: _manageFeeds,
            ),
            const TrellisThemeToggle(),
            OhBarOverflow<String>(
              key: const Key('river-more'),
              onSelected: (choice) => switch (choice) {
                'jobs' => widget.onOpenJobs?.call(),
                'history' => _openHistory(),
                'select' => _selection.enter(),
                _ => _openQueue(),
              },
              itemBuilder: (_) => [
                if (_entries?.isNotEmpty ?? false)
                  const PopupMenuItem(
                    key: Key('river-select'),
                    value: 'select',
                    child: Text('Select'),
                  ),
                const PopupMenuItem(
                  key: Key('river-open-history'),
                  value: 'history',
                  child: Text('History'),
                ),
                const PopupMenuItem(
                  key: Key('river-open-queue'),
                  value: 'queue',
                  child: Text('Up Next'),
                ),
                if (widget.onOpenJobs != null)
                  const PopupMenuItem(
                    key: Key('river-open-jobs'),
                    value: 'jobs',
                    child: Text('Jobs'),
                  ),
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
            _decayedNotice(),
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
        _decayedNotice(),
        _filterChips(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: visible.length,
              itemBuilder: (_, i) => _itemTile(visible, i),
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
    // The shed-leaves law (proposal-2 §12): an ephemeron carries a leaf that
    // fades toward its sweep day; promoted works persist and carry nothing.
    // Same day arithmetic as the boot sweep — see river_decay.dart.
    final isEphemeron = e.work.persistence == 'ephemeron';
    final held = _held.contains(e.work.id);
    // A held row is not counting down: full leaf, and it says why it stays.
    final daysLeft = held
        ? 31
        : ephemeraDaysLeft(
            firstSeenEpochDay: e.work.firstSeenEpochDay,
            todayEpochDay: epochDayUtcNow(),
          );
    final drift = !isEphemeron
        ? null
        : held
            ? heldSubtitle
            : driftSubtitle(daysLeft);
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
      selected: selecting ? _selection.contains(e.work.id) : null,
      onLongPress: selecting
          ? () => _selection.toggle(e.work.id)
          : () => _selection.enter(e.work.id),
      metaLead: isEphemeron
          ? Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Opacity(
                key: Key('leaf-${e.work.id}'),
                opacity: leafOpacity(daysLeft),
                child: const Icon(
                  Icons.eco,
                  size: 14,
                  color: OhColors.sage500,
                ),
              ),
            )
          : null,
      below: [
        if (drift != null)
          Text(
            drift,
            key: Key('drift-${e.work.id}'),
            style: theme.textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
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
        'mark-older' => _bulk.markOlderPlayed(context, _olderUnplayed(visible, e)),
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
        if (isAudio && _olderUnplayed(visible, e).isNotEmpty)
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
                Icons.inbox_outlined,
                size: 56,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                'Your Inbox is empty.',
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                // The 30-day rule stated in the same breath as the no-
                // ranking promise (audit rank 4): leaving is a decision.
                'New episodes and articles from the feeds you follow arrive '
                'here, newest first, never ranked. What you don’t keep '
                'leaves after 30 days.',
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
