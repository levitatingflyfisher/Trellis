import 'dart:convert';

import 'package:comms_core/comms_core.dart';
import 'package:flutter/material.dart';

import '../../db/database.dart' hide Alignment;
import '../../net/io_fetcher.dart';
import '../../services/device_services.dart';
import '../intake/epub_intake.dart';
import '../intake/gutenberg_screen.dart';
import '../intake/paste_intake.dart';
import '../intake/url_intake.dart';
import '../models/format.dart' show formatDay, formatEpochDay;
import '../player/player_controller.dart';
import '../reader/reader_logic.dart' show shouldOfferRecap;
import '../reader/reader_screen.dart';
import '../reader/speech/speech_engine.dart';
import '../reader/speech/speech_temp_files.dart';
import '../reader/translation/marian_engine.dart';
import 'library_filter_screen.dart';
import 'library_filter_sheet.dart';
import 'library_query.dart';

typedef _Entry = ({
  Work work,
  int segmentCount,
  Position? position,
  Episode? episode,
  String? feedTitle,
  // Campaign 7 (ADR-0013): an audiobook has no Segments/Positions rows at
  // all — its progress reads PlayerPositions (fileIdx) and its own file
  // count instead. Both null for every non-audiobook work.
  PlayerPosition? playerPosition,
  int? audiobookFileCount,
});

/// One reader's works: pinned first, then newest; progress is the cursor
/// law's numerator over the segment count. The empty state is an invitation,
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

  /// Resolves a translator for a specific (source, target) pair (Campaign
  /// 8 "Babel widens" Phase 1, generalizing ADR-0008 "Babel" Phase 3) —
  /// the shell closes over `DeviceServices.resolveTranslator`; null keeps
  /// every reader this screen opens without a "Translate…" action, the
  /// same shape as [resolveSpeechEngine].
  final Future<MarianTranslator?> Function(
      {required String sourceLang, required String targetLang})?
      resolveTranslator;

  /// The picker's own data source (Campaign 8 "Babel widens" Phase 1) —
  /// the shell closes over `DeviceServices.availableTranslationTargets`;
  /// null (or an empty result) keeps the "Translate…" action hidden.
  final Future<List<String>> Function({required String sourceLang})?
      availableTranslationTargets;

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
      this.resolveTranslator,
      this.availableTranslationTargets,
      this.onImportAudiobook,
      this.onDeleteAudiobookFiles});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<_Entry>? _entries;
  LibraryQuery? _activeQuery;
  List<SavedViewRow> _savedViews = const [];

  SpineDao get _dao => widget.db.spineDao;

  late final HttpFetcher _fetcher = widget.fetcher ?? IoHttpFetcher();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final queryEntries =
        await widget.db.libraryDao.libraryQueryEntriesOf(widget.profile.id);
    final entries = <_Entry>[
      for (final qe in queryEntries)
        if (qe.work.kind == 'audiobook')
          (
            work: qe.work,
            segmentCount: 0,
            position: null,
            episode: qe.episode,
            feedTitle: qe.feedTitle,
            playerPosition: await widget.db.feedsDao.playerPosition(
                profileId: widget.profile.id, workId: qe.work.id),
            audiobookFileCount:
                await widget.db.audiobooksDao.fileCountOf(qe.work.id),
          )
        else
          (
            work: qe.work,
            segmentCount: await _dao.segmentCount(qe.work.id),
            position: await _dao.position(
                profileId: widget.profile.id, workId: qe.work.id),
            episode: qe.episode,
            feedTitle: qe.feedTitle,
            playerPosition: null,
            audiobookFileCount: null,
          )
    ];
    entries.sort((a, b) {
      if (a.work.pinned != b.work.pinned) return a.work.pinned ? -1 : 1;
      return b.work.id.compareTo(a.work.id); // newest first
    });
    final savedViews = await widget.db.libraryDao.savedViewsOf(widget.profile.id);
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _savedViews = savedViews;
    });
  }

  /// The filtered view of [_entries] — pure, re-evaluated on every build
  /// rather than stored, so applying/clearing a filter never needs a DB
  /// round-trip.
  List<_Entry> get _visibleEntries {
    final entries = _entries ?? const [];
    final query = _activeQuery;
    if (query == null) return entries;
    return [
      for (final e in entries)
        if (matchesLibraryQuery(
            (work: e.work, episode: e.episode, feedTitle: e.feedTitle), query))
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
      setState(() => _activeQuery = null);
      return;
    }
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => LibraryFilterSheet(
        db: widget.db,
        profileId: widget.profile.id,
        initial: active ?? const LibraryQuery(),
        onChanged: (q) =>
            setState(() => _activeQuery = q.isEmpty ? null : q),
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
      setState(() => _activeQuery = result.isEmpty ? null : result);
    }
    await _load(); // a view may have been created/deleted/reordered too
  }

  void _applySavedView(SavedViewRow v) {
    final query = LibraryQuery.fromJson(
        jsonDecode(v.queryJson) as Map<String, Object?>);
    setState(() => _activeQuery = query.isEmpty ? null : query);
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
    } on FormatException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("That file couldn't be read as an EPUB.")));
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

  Future<void> _remove(_Entry e) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text("Remove '${e.work.title}'?"),
        content:
            const Text('It leaves this library; nothing else is touched.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Keep it')),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Remove from library')),
        ],
      ),
    );
    if (confirmed != true) return;
    // Campaign 7 (ADR-0013): deleteWork only ever removes DB rows (the
    // same law ADR-0012 recorded for a downloaded episode's audio file) —
    // an audiobook's copied bytes on disk are this screen's own job to
    // clear, or Remove silently leaks the whole book.
    if (e.work.kind == 'audiobook') widget.onDeleteAudiobookFiles?.call(e.work.id);
    await _dao.deleteWork(e.work.id);
    await _load();
  }

  Future<void> _open(_Entry e) async {
    // Campaign 7 (ADR-0013): "the audiobook opens into the EXISTING
    // player surface" — there is no separate audiobook reader screen,
    // tapping the tile starts playback and the persistent mini player bar
    // (chapters, speed, sleep timer, bookmark) is the whole interface
    // from here.
    if (e.work.kind == 'audiobook') {
      await widget.player?.playAudiobook(e.work);
      if (!mounted) return;
      await _load();
      return;
    }
    // Resolved before the push (ADR-0006): the neural-voice hint and the
    // settings-escape menu both need to know whether a voice exists BEFORE
    // the reader ever shows its first frame — cheap (a directory-exists
    // check at most), never touched on a tier that can't run local ML.
    final resolver = widget.resolveSpeechEngine;
    final hasVoice = resolver == null
        ? false
        : await resolver(lang: e.work.lang) != null;
    if (!mounted) return;
    // Campaign 4 Phase 4: same "resolved before the push" shape as
    // offerNeuralVoice above — shouldOfferRecap's own trigger rules are
    // pure and tested in isolation (reader_logic_test.dart); this is just
    // the real Position/segmentCount data feeding them.
    final position = e.position;
    final offerRecap = shouldOfferRecap(
        lastTouchedEpochDay: position == null
            ? null
            : position.updatedAtMs ~/ Duration.millisecondsPerDay,
        todayEpochDay: epochDayUtcNow(),
        progress: e.segmentCount == 0
            ? 0
            : (position?.segmentIdx ?? 0) / e.segmentCount);
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ReaderScreen(
          db: widget.db,
          profileId: widget.profile.id,
          work: e.work,
          tts: widget.tts,
          offerNeuralVoice: widget.localMlAvailable && !hasVoice,
          resolveSpeechEngine: widget.resolveSpeechEngine,
          lookupDefinition: widget.lookupDefinition,
          createSpeechTempFiles: widget.createSpeechTempFiles,
          player: widget.player,
          resolveTranslator: widget.resolveTranslator,
          availableTranslationTargets: widget.availableTranslationTargets,
          offerRecap: offerRecap),
    ));
    await _load(); // progress may have moved
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    final hasFilter = _activeQuery != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          IconButton(
            key: const Key('open-filter'),
            tooltip: hasFilter ? 'Clear filter' : 'Filter & saved views',
            icon: Icon(hasFilter ? Icons.filter_alt_off : Icons.filter_alt_outlined),
            onPressed: _openFilter,
          ),
          if (widget.onOpenModels != null)
            IconButton(
              key: const Key('open-models'),
              tooltip: 'On this device',
              icon: const Icon(Icons.memory_outlined),
              onPressed: widget.onOpenModels,
            ),
          TextButton.icon(
            key: const Key('profile-switcher'),
            onPressed: widget.onSwitchProfile,
            icon: const Icon(Icons.person_outline),
            // AppBar actions get intrinsic width — without a bound the
            // ellipsis never engages and long names overflow at 320dp.
            label: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 108),
              child: Text(widget.profile.name,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  softWrap: false),
            ),
          ),
        ],
      ),
      floatingActionButton: (entries == null || entries.isEmpty)
          ? null
          : FloatingActionButton.extended(
              onPressed: _addSheet,
              icon: const Icon(Icons.add),
              label: const Text('Add')),
      body: switch (entries) {
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
              Expanded(child: _libraryList(_visibleEntries)),
            ],
          ),
      },
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

  /// Progress for an audiobook (ADR-0013): file-count-coarse — how many of
  /// the book's files the stored position has reached, ignoring the exact
  /// offset within the current one. Deliberately not time-precise (a
  /// per-file duration is only ever learned once that file has actually
  /// played — see [AudiobookFiles.durationMs]), the same Voice/SABP-shape
  /// honesty the spec asks for.
  double _audiobookProgress(_Entry e) {
    final count = e.audiobookFileCount ?? 0;
    if (count == 0) return 0.0;
    final fileIdx = e.playerPosition?.fileIdx ?? 0;
    return (fileIdx / count).clamp(0.0, 1.0);
  }

  /// Campaign 9 Phase 4: user: "library rows have no dates." An episode's
  /// date is when the HOST published it (what a listener actually cares
  /// about, independent of whenever it happened to be kept); every other
  /// kind falls back to when it was first added — the same distinction
  /// the river already draws between an episode row's own date and
  /// anything else.
  String _dateLabel(_Entry e) {
    final episode = e.episode;
    return episode != null
        ? formatDay(episode.publishedAtMs)
        : formatEpochDay(e.work.firstSeenEpochDay);
  }

  Widget _workTile(_Entry e) {
    final progress = e.work.finishedEpochDay != null
        ? 1.0
        : e.work.kind == 'audiobook'
            ? _audiobookProgress(e)
            : e.segmentCount == 0
                ? 0.0
                : ((e.position?.segmentIdx ?? 0) / e.segmentCount)
                    .clamp(0.0, 1.0);
    return ListTile(
      onTap: () => _open(e),
      leading: Icon(switch (e.work.kind) {
        'book' => Icons.menu_book_outlined,
        'article' => Icons.article_outlined,
        'audiobook' => Icons.headphones_outlined,
        _ => Icons.notes_outlined,
      }),
      title: Text(e.work.title, overflow: TextOverflow.ellipsis, maxLines: 2),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(_dateLabel(e),
                key: Key('date-${e.work.id}'),
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: LinearProgressIndicator(
                value: progress, borderRadius: BorderRadius.circular(2)),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (e.work.pinned)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Icon(Icons.push_pin, size: 18),
            ),
          PopupMenuButton<String>(
            key: Key('work-menu-${e.work.id}'),
            tooltip: 'More',
            onSelected: (v) => switch (v) {
              'pin' => _togglePin(e),
              _ => _remove(e),
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                  value: 'pin',
                  child: Text(e.work.pinned ? 'Unpin' : 'Pin')),
              const PopupMenuItem(value: 'remove', child: Text('Remove')),
            ],
          ),
        ],
      ),
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
