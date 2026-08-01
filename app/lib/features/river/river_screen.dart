import 'dart:async';

import 'package:flutter/material.dart';
import 'package:openhearth_design/openhearth_design.dart';

import '../../db/database.dart';
import '../feeds/feeds_repository.dart';
import '../feeds/feeds_screen.dart';
import '../feeds/subscribe_screen.dart';
import '../intake/paste_intake.dart' show epochDayUtcNow;
import '../models/consent.dart';
import '../models/format.dart';
import '../models/models_screen.dart' show modelLabel;
import '../player/player_controller.dart';
import '../reader/reader_screen.dart';
import '../reader/speech/speech_engine.dart';
import '../reader/speech/speech_temp_files.dart';
import '../transcribe/job_cards.dart';
import '../transcribe/transcribe_coordinator.dart';
import 'river_decay.dart';

/// The River (ADR-0003 law 1): ONE reverse-chronological list across every
/// feed. The order comes from the DAO's single query and is never touched
/// here — the chips FILTER, they do not sort; no ranking code path exists.
class RiverScreen extends StatefulWidget {
  final AppDatabase db;
  final Profile profile;
  final FeedsRepository repository;
  final PlayerController playerController;
  final TranscribeCoordinator coordinator;

  /// DeviceServices.localMlAvailable, handed down by the shell. Where
  /// false (the web tier) the transcribe menu is simply not offered —
  /// play still works; the UI never offers what must fail.
  final bool localMlAvailable;

  /// Resolves the neural voice for a work's language (ADR-0006) — the
  /// shell closes over `DeviceServices.resolveSpeechEngine`; null keeps
  /// every reader this screen opens on the system voice.
  final Future<SynthesisSpeechEngine?> Function({String? lang})?
      resolveSpeechEngine;

  /// See `LibraryScreen.createSpeechTempFiles`.
  final SpeechTempFiles Function()? createSpeechTempFiles;

  const RiverScreen(
      {super.key,
      required this.db,
      required this.profile,
      required this.repository,
      required this.playerController,
      required this.coordinator,
      this.localMlAvailable = true,
      this.resolveSpeechEngine,
      this.createSpeechTempFiles});

  @override
  State<RiverScreen> createState() => _RiverScreenState();
}

enum _RiverFilter { all, text, audio }

class _RiverScreenState extends State<RiverScreen> {
  List<RiverEntry>? _entries;
  _RiverFilter _filter = _RiverFilter.all;

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
    final followed = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => SubscribeScreen(
            repository: widget.repository, profileId: widget.profile.id)));
    if (followed == true) await _load();
  }

  Future<void> _manageFeeds() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => FeedsScreen(
            db: widget.db,
            repository: widget.repository,
            profile: widget.profile)));
    await _load();
  }

  Future<void> _openItem(RiverEntry e) async {
    await widget.db.feedsDao
        .markRead(e.work.id, DateTime.now().millisecondsSinceEpoch);
    if (!mounted) return;
    // See LibraryScreen._open — same resolve-before-push shape (ADR-0006).
    final resolver = widget.resolveSpeechEngine;
    final hasVoice = resolver == null
        ? false
        : await resolver(lang: e.work.lang) != null;
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ReaderScreen(
          db: widget.db,
          profileId: widget.profile.id,
          work: e.work,
          offerNeuralVoice: widget.localMlAvailable && !hasVoice,
          resolveSpeechEngine: widget.resolveSpeechEngine,
          createSpeechTempFiles: widget.createSpeechTempFiles),
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
    final plan =
        await coordinator.planFor(workId: e.work.id, enclosureUrl: url);
    if (!mounted) return;
    if (plan.needsDownloads) {
      final ok = await confirmDownload(context, items: [
        if (plan.needsModel)
          DownloadItem('${modelLabel(plan.model.id)} '
              '(${formatBytes(plan.model.sizeBytes)}) — one time'),
        if (plan.needsAudio)
          DownloadItem(
              'This episode’s audio (size depends on the episode)'),
      ]);
      if (!ok) return;
    }
    unawaited(coordinator.start(
        workId: e.work.id,
        title: e.work.title,
        enclosureUrl: url,
        lang: e.work.lang,
        translate: translate));
  }

  List<RiverEntry> get _visible {
    final entries = _entries ?? const [];
    return switch (_filter) {
      _RiverFilter.all => entries,
      _RiverFilter.text =>
        [for (final e in entries) if (e.episode.enclosureUrl == null) e],
      _RiverFilter.audio =>
        [for (final e in entries) if (e.episode.enclosureUrl != null) e],
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
        todayEpochDay: epochDayUtcNow());
    final drift = isEphemeron ? driftSubtitle(daysLeft) : null;
    return ListTile(
      onTap: () => _openItem(e),
      leading: SizedBox(
        width: 12,
        child: unread
            ? Center(
                child: Container(
                  key: Key('unread-dot-${e.work.id}'),
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      shape: BoxShape.circle),
                ),
              )
            : null,
      ),
      title: Text(e.work.title,
          overflow: TextOverflow.ellipsis,
          maxLines: 2,
          style: unread
              ? theme.textTheme.bodyLarge
                  ?.copyWith(fontWeight: FontWeight.w600)
              : theme.textTheme.bodyLarge),
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
                    child: const Icon(Icons.eco,
                        size: 14, color: OhColors.sage500),
                  ),
                ),
              Expanded(
                child: Text(
                    '${e.feedTitle.isEmpty ? 'Feed' : e.feedTitle} · '
                    '${_formatDay(e.episode.publishedAtMs)}',
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1),
              ),
            ],
          ),
          if (drift != null)
            Text(drift,
                key: Key('drift-${e.work.id}'),
                style: theme.textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
                maxLines: 1),
        ],
      ),
      trailing: isAudio
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: Key('play-${e.work.id}'),
                  tooltip: 'Play',
                  icon: const Icon(Icons.play_circle_outline, size: 32),
                  onPressed: () => _playItem(e),
                ),
                if (widget.localMlAvailable)
                  PopupMenuButton<String>(
                    key: Key('menu-${e.work.id}'),
                    tooltip: 'More',
                    onSelected: (choice) => _transcribe(e,
                        translate: choice == 'translate'),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                          key: Key('transcribe-${e.work.id}'),
                          value: 'transcribe',
                          child: const Text('Transcribe')),
                      PopupMenuItem(
                          key: Key('translate-${e.work.id}'),
                          value: 'translate',
                          child:
                              const Text('Transcribe + translate to English')),
                    ],
                  ),
              ],
            )
          : null,
    );
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _formatDay(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.day} ${_months[d.month - 1]}';
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
              Icon(Icons.waves,
                  size: 56, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text('The river is quiet.',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(
                  'Follow the feeds and podcasts you choose. '
                  'Newest first — nothing decides for you.',
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton.icon(
                  onPressed: onFollow,
                  icon: const Icon(Icons.rss_feed),
                  label: const Text('Follow a feed')),
            ],
          ),
        ),
      ),
    );
  }
}
