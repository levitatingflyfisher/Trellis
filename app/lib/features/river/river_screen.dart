import 'dart:async';

import 'package:flutter/material.dart';
import 'package:openhearth_design/openhearth_design.dart';

import '../../db/database.dart' hide Alignment;
import '../dsp/dsp_coordinator.dart';
import '../dsp/dsp_params.dart' show effectiveDspEnabled;
import '../feeds/episode_download_coordinator.dart';
import '../feeds/feeds_repository.dart';
import '../feeds/feeds_screen.dart';
import '../feeds/subscribe_screen.dart';
import '../intake/paste_intake.dart' show epochDayUtcNow;
import '../models/consent.dart';
import '../models/format.dart';
import '../models/models_screen.dart' show modelLabel;
import '../player/player_controller.dart';
import '../player/queue_screen.dart';
import '../reader/reader_screen.dart';
import '../reader/speech/speech_engine.dart';
import '../reader/speech/speech_temp_files.dart';
import '../reader/translation/marian_engine.dart';
import '../transcribe/job_cards.dart';
import '../transcribe/transcribe_coordinator.dart';
import 'river_decay.dart';
import 'river_triage.dart';

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

  const RiverScreen(
      {super.key,
      required this.db,
      required this.profile,
      required this.repository,
      required this.playerController,
      required this.coordinator,
      this.downloadCoordinator,
      this.dspCoordinator,
      this.localMlAvailable = true,
      this.resolveSpeechEngine,
      this.lookupDefinition,
      this.createSpeechTempFiles,
      this.resolveTranslator,
      this.availableTranslationTargets});

  @override
  State<RiverScreen> createState() => _RiverScreenState();
}

enum _RiverFilter { all, text, audio }

class _RiverScreenState extends State<RiverScreen> {
  List<RiverEntry>? _entries;
  _RiverFilter _filter = _RiverFilter.all;
  late final RiverTriage _triage = RiverTriage(widget.db);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await widget.db.feedsDao.riverItems(widget.profile.id);
    if (!mounted) return;
    setState(() => _entries = entries);
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

  Future<void> _manageFeeds() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => FeedsScreen(
          db: widget.db,
          repository: widget.repository,
          profile: widget.profile,
          localMlAvailable: widget.localMlAvailable,
        ),
      ),
    );
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

  Future<void> _playNext(RiverEntry e) async {
    await widget.db.queueDao.playNext(
      profileId: widget.profile.id,
      workId: e.work.id,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _playLast(RiverEntry e) async {
    await widget.db.queueDao.playLast(
      profileId: widget.profile.id,
      workId: e.work.id,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
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
              '(${formatBytes(plan.model.sizeBytes)}) — one time',
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

  /// The standalone Download entry (Campaign 6): the SAME one consent
  /// chokepoint transcribe uses (ADR-0003 law 6 — there is no second
  /// door), for the plain "listen offline" case that doesn't touch a
  /// transcript.
  Future<void> _download(RiverEntry e) async {
    final url = e.episode.enclosureUrl;
    final downloader = widget.downloadCoordinator;
    if (url == null || downloader == null) return;
    if (downloader.isDownloaded(e.work.id, url)) return;
    final ok = await confirmDownload(
      context,
      items: const [
        DownloadItem('This episode’s audio (size depends on the episode)'),
      ],
    );
    if (!ok) return;
    await downloader.start(workId: e.work.id, url: url);
    await _maybeProcess(e, url);
    await _load(); // the quiet downloaded indicator picks up disk truth
  }

  /// "Processed on download, on this device" — the offline DSP
  /// preprocess's whole promise (Campaign 6, ADR-0012). Runs
  /// automatically right after a Download that actually landed a file,
  /// and only when this feed's effective setting (its own override, or
  /// the household default) says yes. A failed or skipped download
  /// leaves nothing on disk to process, so the disk check below is the
  /// same honest guard [EpisodeDownloadCoordinator.isDownloaded] uses
  /// everywhere else.
  Future<void> _maybeProcess(RiverEntry e, String url) async {
    final processor = widget.dspCoordinator;
    final downloader = widget.downloadCoordinator;
    if (processor == null || downloader == null) return;
    if (!downloader.isDownloaded(e.work.id, url)) return;
    final feed = await widget.db.feedsDao.feedById(e.episode.feedId);
    final globalDefault = await widget.db.profilesDao.dspGlobalDefault(
      widget.profile.id,
    );
    final enabled = effectiveDspEnabled(
      feedOverride: feed?.dspEnabled,
      globalDefault: globalDefault,
    );
    if (!enabled) return;
    await processor.start(workId: e.work.id, title: e.work.title, url: url);
  }

  /// Disk truth for the quiet indicator — false (never a throw) whenever
  /// there's no coordinator (web tier) or no enclosure to check.
  bool _isDownloaded(RiverEntry e) {
    final url = e.episode.enclosureUrl;
    final downloader = widget.downloadCoordinator;
    if (url == null || downloader == null) return false;
    return downloader.isDownloaded(e.work.id, url);
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
        content: const Text('Kept — now in your library'),
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
      appBar: AppBar(
        title: const Text('River'),
        actions: [
          IconButton(
            key: const Key('river-open-queue'),
            tooltip: 'Up Next',
            icon: const Icon(Icons.queue_music_outlined),
            onPressed: _openQueue,
          ),
          IconButton(
            key: const Key('manage-feeds'),
            tooltip: 'Manage feeds',
            icon: const Icon(Icons.rss_feed),
            onPressed: _manageFeeds,
          ),
        ],
      ),
      body: switch (entries) {
        null => const Center(child: CircularProgressIndicator()),
        [] => Column(
          children: [
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
        _ => Column(
          children: [
            TranscribeJobCards(coordinator: widget.coordinator),
            _filterChips(),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _refresh,
                child: ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: _visible.length,
                  itemBuilder: (_, i) => _itemTile(_visible[i]),
                ),
              ),
            ),
          ],
        ),
      },
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
            onSelected: (_) => setState(() => _filter = _RiverFilter.all),
          ),
          const SizedBox(width: 8),
          ChoiceChip(
            key: const Key('chip-text'),
            label: const Text('Text'),
            selected: _filter == _RiverFilter.text,
            onSelected: (_) => setState(() => _filter = _RiverFilter.text),
          ),
          const SizedBox(width: 8),
          ChoiceChip(
            key: const Key('chip-audio'),
            label: const Text('Audio'),
            selected: _filter == _RiverFilter.audio,
            onSelected: (_) => setState(() => _filter = _RiverFilter.audio),
          ),
        ],
      ),
    );
  }

  Widget _itemTile(RiverEntry e) {
    final theme = Theme.of(context);
    final unread = e.episode.readAtMs == null;
    final isAudio = e.episode.enclosureUrl != null;
    // The shed-leaves law (proposal-2 §12): an ephemeron carries a leaf that
    // fades toward its sweep day; promoted works persist and carry nothing.
    // Same day arithmetic as the boot sweep — see river_decay.dart.
    final isEphemeron = e.work.persistence == 'ephemeron';
    final daysLeft = ephemeraDaysLeft(
      firstSeenEpochDay: e.work.firstSeenEpochDay,
      todayEpochDay: epochDayUtcNow(),
    );
    final drift = isEphemeron ? driftSubtitle(daysLeft) : null;
    // P4 "archive, never forget": the row is never gone, only its audio
    // file — dimmed rather than hidden makes that visible truth instead of
    // an assertion nobody can check.
    final isArchived = e.episode.archivedAtMs != null;
    final tile =
        _tile(e, theme, unread, isAudio, isEphemeron, daysLeft, drift);
    final dimmed = isArchived
        ? Opacity(key: Key('archived-${e.work.id}'), opacity: 0.55, child: tile)
        : tile;
    // Swipe Keep / Let it pass (Campaign 5): confirmDismiss performs the
    // gesture then always returns false, so the tile springs back showing
    // its new state — the house idiom (archived rows dim rather than
    // vanish) applied to triage too. Nothing is ever removed from the
    // river by a swipe; only tap-to-open already changes what's visible
    // here, and only via the unread dot.
    return Dismissible(
      key: Key('swipe-${e.work.id}'),
      direction: DismissDirection.horizontal,
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
      child: dimmed,
    );
  }

  /// The row's leading slot (Campaign 9 Phase 5, "the river gets faces"):
  /// a ~40dp rounded artwork thumbnail when the feed's channel image was
  /// already downloaded to its deterministic local file — never fetched
  /// here, only read — with the unread dot riding as a small corner badge
  /// instead of the dot's own dedicated 12dp column. A feed with no
  /// downloaded artwork keeps today's plain dot-only layout unchanged.
  Widget _leading(RiverEntry e, ThemeData theme, bool unread) {
    final dot = Container(
      key: Key('unread-dot-${e.work.id}'),
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        shape: BoxShape.circle,
      ),
    );
    // The web-tier law (see this file's own class doc + `_isDownloaded`
    // above): never call a real dart:io op where none works. `existsSync()`
    // throws under dart2js, so the artwork lookup is gated on
    // localMlAvailable exactly like the download door is, rather than on
    // services being present — a detached/real DeviceServices is non-null
    // on every tier, web included.
    final services = widget.localMlAvailable ? widget.repository.services : null;
    final artFile = services?.artworkFileFor(e.episode.feedId);
    if (artFile == null || !artFile.existsSync()) {
      return SizedBox(
        width: 12,
        child: unread ? Center(child: dot) : null,
      );
    }
    return SizedBox(
      width: 40,
      height: 40,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Opacity(
              // Calm: full presence while unread, quietly muted once read —
              // the same "read fades, nothing vanishes" law the ephemeron
              // leaf already applies elsewhere in this row.
              opacity: unread ? 1.0 : 0.7,
              child: Image.file(
                artFile,
                key: Key('artwork-${e.work.id}'),
                width: 40,
                height: 40,
                fit: BoxFit.cover,
                // A partial/corrupt download must never crash a row — it
                // just reads as "no thumbnail yet", same as a file that
                // was never downloaded at all.
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
          if (unread)
            Positioned(
              top: -3,
              right: -3,
              child: Container(
                padding: const EdgeInsets.all(1.5),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  shape: BoxShape.circle,
                ),
                child: dot,
              ),
            ),
        ],
      ),
    );
  }

  Widget _tile(
    RiverEntry e,
    ThemeData theme,
    bool unread,
    bool isAudio,
    bool isEphemeron,
    int daysLeft,
    String? drift,
  ) {
    return ListTile(
      onTap: () => _openItem(e),
      leading: _leading(e, theme, unread),
      title: Text(
        e.work.title,
        overflow: TextOverflow.ellipsis,
        maxLines: 2,
        style: unread
            ? theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)
            : theme.textTheme.bodyLarge,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (isEphemeron)
                Padding(
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
                ),
              Expanded(
                child: Text(
                  '${e.feedTitle.isEmpty ? 'Feed' : e.feedTitle} · '
                  '${formatDay(e.episode.publishedAtMs)}',
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ],
          ),
          if (drift != null)
            Text(
              drift,
              key: Key('drift-${e.work.id}'),
              style: theme.textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
        ],
      ),
      // Overflow parity (ergonomic-ux): every row gets the menu, audio or
      // not — swipe is the fast path, the menu is the reachable-by-anyone
      // path, and Keep/Let it pass live in both.
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isAudio && _isDownloaded(e))
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(
                Icons.download_done,
                key: Key('downloaded-${e.work.id}'),
                size: 18,
                color: theme.colorScheme.primary,
              ),
            ),
          if (isAudio)
            IconButton(
              key: Key('play-${e.work.id}'),
              tooltip: 'Play',
              icon: const Icon(Icons.play_circle_outline, size: 32),
              onPressed: () => _playItem(e),
            ),
          PopupMenuButton<String>(
            key: Key('menu-${e.work.id}'),
            tooltip: 'More',
            onSelected: (choice) => switch (choice) {
              'keep' => _keep(e),
              'pass' => _letItPass(e),
              'play-next' => _playNext(e),
              'play-last' => _playLast(e),
              'download' => _download(e),
              _ => _transcribe(e, translate: choice == 'translate'),
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                  key: Key('keep-${e.work.id}'),
                  value: 'keep',
                  child: const Text('Keep')),
              PopupMenuItem(
                  key: Key('pass-${e.work.id}'),
                  value: 'pass',
                  child: const Text('Let it pass')),
              if (isAudio) ...[
                PopupMenuItem(
                    key: Key('play-next-${e.work.id}'),
                    value: 'play-next',
                    child: const Text('Play next')),
                PopupMenuItem(
                    key: Key('play-last-${e.work.id}'),
                    value: 'play-last',
                    child: const Text('Play last')),
                if (widget.localMlAvailable &&
                    widget.downloadCoordinator != null &&
                    !_isDownloaded(e))
                  PopupMenuItem(
                      key: Key('download-${e.work.id}'),
                      value: 'download',
                      child: const Text('Download')),
                if (widget.localMlAvailable) ...[
                  PopupMenuItem(
                      key: Key('transcribe-${e.work.id}'),
                      value: 'transcribe',
                      child: Text(e.episode.archivedAtMs != null
                          ? 'Re-download audio'
                          : 'Transcribe')),
                  PopupMenuItem(
                      key: Key('translate-${e.work.id}'),
                      value: 'translate',
                      child:
                          const Text('Transcribe + translate to English')),
                ],
              ],
            ],
          ),
        ],
      ),
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
                Icons.waves,
                size: 56,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                'The river is quiet.',
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Follow the feeds and podcasts you choose. '
                'Newest first — nothing decides for you.',
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
