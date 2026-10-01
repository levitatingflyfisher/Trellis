import 'dart:async';

import 'package:comms_core/comms_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../../services/device_services.dart';
import '../backup/backup_screen.dart';
import '../dsp/dsp_coordinator.dart';
import '../echo/echo_screen.dart';
import '../episodes/episode_actions.dart';
import '../feeds/background/feed_check_settings.dart';
import '../feeds/episode_download_coordinator.dart';
import '../feeds/feeds_repository.dart';
import '../feeds/feed_detail_screen.dart';
import '../feeds/feeds_screen.dart';
import '../feeds/subscribe_screen.dart';
import '../home_widget/home_widget_host.dart';
import '../home_widget/widget_snapshot_writer.dart';
import '../intake/audiobook_import.dart';
import '../intake/audiobook_import_screen.dart';
import '../intake/audiobook_picker_gateway.dart';
import '../intake/share_intake.dart';
import '../intake/share_queue.dart';
import '../jobs/job_center.dart';
import '../jobs/jobs_screen.dart';
import '../library/library_screen.dart';
import '../models/models_screen.dart';
import '../player/accelerometer_samples.dart';
import '../player/audiobook_chapters.dart';
import '../player/captures_screen.dart';
import '../player/chapters_screen.dart';
import '../player/episode_player.dart';
import '../player/mini_player_bar.dart';
import '../player/mini_player_host.dart';
import '../player/player_controller.dart';
import '../player/queue_screen.dart';
import '../reader/reader_doors.dart';
import '../river/river_screen.dart';
import '../search/search_screen.dart';
import '../study/courses_screen.dart';
import '../transcribe/transcribe_coordinator.dart';
import '../works/work_open.dart';

/// One reader's shell: Latest, Queue, Library and Courses tabs over a single
/// persistent mini-player bar. The player, the feeds repository and the
/// transcription coordinator live here so playback and running jobs
/// survive tab switches — and reopening the app finds its resumable job
/// cards (the coordinator restores them from the jobs table on init).
class HomeShell extends StatefulWidget {
  final AppDatabase db;
  final Profile profile;
  final VoidCallback onSwitchProfile;
  final HttpFetcher fetcher;
  final EpisodePlayer Function() createPlayer;
  final DeviceServices services;
  const HomeShell({
    super.key,
    required this.db,
    required this.profile,
    required this.onSwitchProfile,
    required this.fetcher,
    required this.createPlayer,
    required this.services,
    required this.jobs,
    this.feedCheck,
    this.afterFeedsChecked,
    this.writesReady,
    this.shares,
    this.homeWidget,
  });

  /// Shares from other apps (1.5.5), taken once this reader's shell is up.
  final ShareQueue? shares;

  /// The home-screen widget (1.5.5): this shell writes its card and
  /// answers its taps.
  final HomeWidgetHost? homeWidget;

  /// Every long job on the device; owned above this shell (see JobCenter).
  final JobCenter jobs;

  /// The device's background-check switches, shown on "Models & storage"
  /// where the system can run a check. Owned above this shell, like jobs.
  final FeedCheckSettings? feedCheck;

  /// Runs after a pull-to-refresh finishes: asks for an auto-download pass
  /// when an opted-in show has something new (ADR-0018).
  final Future<void> Function()? afterFeedsChecked;

  /// Completes once a background check that was running at launch has
  /// closed its connection; this shell's own start-up writes wait for it.
  final Future<void>? writesReady;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  static const _queueTab = 1;
  static const _libraryTab = 2;

  /// Latest first, and where a reader lands: what arrived is the usual
  /// reason to open a podcast app.
  int _tab = 0;

  /// One Navigator per tab (1.5.8, user: "like AntennaPod, the bottom nav
  /// bar almost never goes away"): a page opened from a tab opens inside
  /// it, under the same top and bottom bars, and each tab keeps its own
  /// pages while another is in view. Only the reader takes the whole
  /// screen, on the app's Navigator.
  final _tabNavigators = List.generate(4, (_) => GlobalKey<NavigatorState>());
  late final _tabRoutes =
      List.generate(4, (_) => _TabRoutes()..addListener(_onTabRoutesChanged));

  /// Tabs are built on first visit and then kept, so their pages survive
  /// a trip elsewhere; launch still builds only Latest.
  final Set<int> _builtTabs = {0};

  /// Bumped when a tab other than Latest is revisited at its root, so its
  /// screen reads its data again, as it did when tabs were built per
  /// visit (a Keep in Latest, a Library removal show at once).
  final List<int> _tabEpochs = [0, 0, 0, 0];

  // canPop below changes as pages come and go.
  void _onTabRoutesChanged() {
    if (mounted) setState(() {});
  }

  NavigatorState? _tabNavigator(int tab) => _tabNavigators[tab].currentState;

  bool get _tabCanPop => _tabNavigator(_tab)?.canPop() ?? false;

  /// Shows [tab]. A tap on the tab already in view goes back to its root.
  void _selectTab(int tab) {
    if (tab == _tab) {
      _popTabToRoot(tab);
      return;
    }
    _goToTab(tab);
  }

  void _goToTab(int tab) {
    setState(() {
      if (tab != 0 &&
          _builtTabs.contains(tab) &&
          !(_tabNavigator(tab)?.canPop() ?? false)) {
        _tabEpochs[tab]++;
      }
      _builtTabs.add(tab);
      _tab = tab;
    });
  }

  /// Pops [tab] to its root, but never past a page that is holding its
  /// pop (Subscriptions lets a pending unfollow land first): that one is
  /// asked to close the usual way and closes itself.
  void _popTabToRoot(int tab) {
    final nav = _tabNavigator(tab);
    if (nav == null) return;
    nav.popUntil((r) =>
        r.isFirst || r.popDisposition == RoutePopDisposition.doNotPop);
    if (nav.canPop()) unawaited(nav.maybePop());
  }

  /// Where a page the shell opens goes: into the tab in view, or over a
  /// full-screen page (the reader) when one is up, so it is never hidden
  /// beneath it.
  BuildContext get _pageContext {
    if (_host?.routes.pageOverRoot ?? false) return context;
    return _tabNavigators[_tab].currentContext ?? context;
  }

  Future<T?> _pushPage<T>(Widget page) => Navigator.of(_pageContext)
      .push<T>(MaterialPageRoute<T>(builder: (_) => page));
  late final FeedsRepository _repository = FeedsRepository(
    db: widget.db,
    fetcher: widget.fetcher,
    services: widget.services,
  )
    ..afterCheck = widget.afterFeedsChecked
    ..offersAutoDownload = widget.afterFeedsChecked != null;
  late final PlayerController _player = PlayerController(
    db: widget.db,
    profileId: widget.profile.id,
    createPlayer: widget.createPlayer,
    accelerometerSamples: realAccelerometerSamples,
    // dart:io's File exists (constructs) but throws UnsupportedError the
    // moment an IO method runs under dart2js — the same reason every
    // other P3 flow in this file is gated on localMlAvailable. Null here
    // means "always stream," exactly this tier's pre-campaign behavior.
    localAudioFileFor: widget.services.localMlAvailable
        ? widget.services.audioFileFor
        : null,
    // Campaign 9 Phase 2e (ADR-0015 Decision 3): the SAME localMlAvailable
    // gate localAudioFileFor above already follows — a real existsSync()
    // read would throw under dart2js, so the web tier never gets a
    // function that could attempt one.
    artworkFileFor: widget.services.localMlAvailable
        ? widget.services.artworkFileFor
        : null,
  );
  TranscribeCoordinator get _coordinator => widget.jobs.transcribe;

  /// Null on the web tier (see JobCenter.forDevice).
  EpisodeDownloadCoordinator? get _downloadCoordinator =>
      widget.jobs.downloads;
  DspCoordinator? get _dspCoordinator => widget.jobs.dsp;

  // A transcript landing mid-playback opens the Page door live (the
  // capture backfill happens in the coordinator itself).
  void _onTranscribed(int workId) => _player.reloadAlignments(workId);

  /// The audiobook door (Campaign 7, ADR-0013) — same web-tier null law:
  /// the picker never returns a usable path on a browser, so the whole
  /// door stays unconstructed there rather than offering something that
  /// would silently do nothing.
  late final AudiobookImportRepository? _audiobookRepository =
      widget.services.localMlAvailable
          ? AudiobookImportRepository(
              db: widget.db,
              destinationFor: widget.services.audiobookFileFor,
            )
          : null;
  late final AudiobookPickerGateway? _audiobookGateway =
      widget.services.localMlAvailable ? FilePickerAudiobookGateway() : null;

  /// Share to Trellis (1.5.5): what other apps hand in, routed and saved.
  late final ShareIntake _shareIntake = ShareIntake(
    db: widget.db,
    profileId: widget.profile.id,
    fetcher: widget.fetcher,
    audiobooks: _audiobookRepository,
  );

  void _onSharesChanged() => unawaited(_takeShares());

  /// Bumped when a share lands in Latest, so the mounted list re-reads.
  int _latestChanges = 0;
  bool _takingShares = false;
  bool _sharesAgain = false;

  /// Saves every share waiting for this reader, one at a time, in the
  /// order they came. Saving touches only the database (a link's page is
  /// read after, off this loop), so the queue never waits on the network
  /// or on a page the person has open. A share stays waiting until it is
  /// saved: a switch of reader mid-queue leaves the rest for this reader's
  /// next visit.
  Future<void> _takeShares() async {
    final shares = widget.shares;
    if (shares == null) return;
    if (_takingShares) {
      _sharesAgain = true;
      return;
    }
    _takingShares = true;
    try {
      await widget.writesReady;
      do {
        _sharesAgain = false;
        while (mounted) {
          final next = await shares.nextFor(widget.profile.id);
          if (next == null) break;
          if (next.attempts >= maxShareAttempts) {
            // It failed (most likely took the app down) every time.
            await shares.drop(next);
            if (mounted) _toast('Couldn’t save a shared item.');
            continue;
          }
          await shares.attempt(next.id);
          final outcome = await _shareIntake.take(next.payload);
          await shares.done(next.id);
          _onShare(outcome, sourceApp: next.payload.sourceApp);
        }
      } while (_sharesAgain && mounted);
    } catch (e) {
      debugPrint('Share: taking shares failed: $e');
    } finally {
      _takingShares = false;
    }
  }

  void _toast(String message, {SnackBarAction? action}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        // Open is a convenience; the line lapses (conformance C14).
        persist: false,
        action: action,
      ));
  }

  SnackBarAction _openAction(int workId) => SnackBarAction(
      label: 'Open', onPressed: () => unawaited(_openSharedWork(workId)));

  /// Says what became of a share. Nothing here waits for a page or a
  /// sheet to close, so the next share is never held up behind it.
  void _onShare(ShareOutcome outcome, {String? sourceApp}) {
    if (!mounted) return;
    switch (outcome) {
      case ShareSaved(existing: true, pageToFetch: null):
        // Shared before: the work it made opens, and nothing is added.
        unawaited(_openSharedWork(outcome.workId));
      case ShareSaved():
        _goToTab(outcome.inLatest ? 0 : _libraryTab);
        if (outcome.inLatest) setState(() => _latestChanges++);
        final where = outcome.inLatest ? 'Latest' : 'your Library';
        final what = outcome.count > 1 ? '${outcome.count} items' : '';
        final saved = outcome.existing
            ? 'Already in Latest. Reading its page again.'
            : what.isEmpty
            ? 'Saved to $where'
            : 'Saved $what to $where';
        final failed = switch (outcome.failed) {
          0 => '',
          1 => ' 1 file couldn’t be opened.',
          final n => ' $n files couldn’t be opened.',
        };
        _toast('$saved$failed', action: _openAction(outcome.workId));
        if (outcome.pageToFetch != null) {
          unawaited(_readSharedPage(outcome, sourceApp));
        }
      case ShareUpgraded():
        // The link row now holds its article; the snackbar stands.
        setState(() => _latestChanges++);
      case ShareOffersFeed():
        unawaited(_offerFeed(outcome));
      case ShareRefused(message: final message, workId: final workId):
        if (workId != null) setState(() => _latestChanges++);
        _toast(message, action: workId == null ? null : _openAction(workId));
    }
  }

  /// A saved link's page, read after the "Saved" line is up.
  Future<void> _readSharedPage(ShareSaved saved, String? sourceApp) async {
    final out = await _shareIntake.fetchPageFor(saved, sourceApp: sourceApp);
    if (out != null) _onShare(out, sourceApp: sourceApp);
  }

  /// A shared link opened from Latest that was never read gets its page
  /// tried again; the row fills in when it arrives.
  Future<void> _refetchOnOpen(int workId) async {
    final up = await _shareIntake.refetchIfLinkOnly(workId);
    if (up != null && mounted) setState(() => _latestChanges++);
  }

  /// The work page of a shared work, as Latest or the Library opens it.
  Future<void> _openSharedWork(int workId) async {
    unawaited(_refetchOnOpen(workId));
    await _openWork(workId);
  }

  WorkDoors get _workDoors => WorkDoors(
        db: widget.db,
        profileId: widget.profile.id,
        readerDoors: _readerDoors,
        actions: _episodeActions,
      );

  /// A work of this reader's with its feed row, or null when it is gone
  /// or another reader's (a widget tap can outlive both).
  Future<({Work work, RiverEntry? row})?> _ownWork(int workId) async {
    final row = await widget.db.feedsDao.riverEntryOf(workId);
    final work = row?.work ?? await widget.db.spineDao.workById(workId);
    if (work == null || work.profileId != widget.profile.id) return null;
    return (work: work, row: row);
  }

  /// A work's page, as Latest or the Library opens it.
  Future<void> _openWork(int workId) async {
    final found = await _ownWork(workId);
    if (found == null || !mounted) return;
    await _workDoors.open(
        _pageContext, (work: found.work, episode: found.row?.episode),
        showTitle: found.row?.feedTitle);
    if (mounted) setState(() => _latestChanges++);
  }

  /// A text in the reader at its saved place: the widget's Continue
  /// reading.
  Future<void> _readWork(int workId) async {
    final found = await _ownWork(workId);
    if (found == null || !mounted) return;
    await _workDoors
        .read(context, (work: found.work, episode: found.row?.episode));
  }

  /// Settles once the last-played work is back on the bar, so a widget
  /// tap that opened the app resumes that work, not nothing.
  late Future<void> _rehydrated;
  WidgetSnapshotWriter? _widgetWriter;
  bool _takingWidgetActions = false;
  bool _widgetActionsAgain = false;

  void _onWidgetActions() => unawaited(_takeWidgetActions());

  /// Answers every widget tap waiting, in order. A tap meant for another
  /// reader has already done its part by opening the app.
  Future<void> _takeWidgetActions() async {
    final host = widget.homeWidget;
    if (host == null || !host.available) return;
    if (_takingWidgetActions) {
      _widgetActionsAgain = true;
      return;
    }
    _takingWidgetActions = true;
    try {
      await _rehydrated;
      do {
        _widgetActionsAgain = false;
        for (final a in await host.takePending()) {
          if (!mounted) return;
          if (a.profileId != null && a.profileId != widget.profile.id) {
            continue;
          }
          await _onWidgetAction(a);
        }
      } while (_widgetActionsAgain && mounted);
    } catch (e) {
      debugPrint('Widget: taking taps failed: $e');
    } finally {
      _takingWidgetActions = false;
    }
  }

  Future<void> _onWidgetAction(WidgetAction a) async {
    switch (a.kind) {
      // Play and Pause, never a toggle: the card may be a moment behind
      // the player, and a tap does what it showed.
      case WidgetActionKind.play:
        // The bar closed since: bring the last-played work back first.
        if (_player.current == null) await _player.rehydrateLastPlayed();
        if (!_player.playing) await _player.toggle();
      case WidgetActionKind.pause:
        if (_player.playing) await _player.toggle();
      case WidgetActionKind.back:
        await _player.seekBy(const Duration(seconds: -15));
      case WidgetActionKind.forward:
        await _player.seekBy(const Duration(seconds: 30));
      // A page stays open until closed, so it is never awaited here: the
      // next tap must not wait behind it.
      case WidgetActionKind.openWork:
        final id = a.workId;
        if (id != null) unawaited(_openWork(id));
      case WidgetActionKind.read:
        final id = a.workId;
        if (id != null) unawaited(_readWork(id));
    }
  }

  /// A feed, a profile or a front page: follow it, or keep the page.
  Future<void> _offerFeed(ShareOffersFeed offer) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => _SubscribeSheet(offer: offer),
    );
    if (!mounted) return;
    switch (choice) {
      case 'subscribe':
        final result = await _repository.subscribe(
            profileId: widget.profile.id, rawUrl: offer.feedUrl);
        if (!mounted) return;
        switch (result) {
          case SubscribeSuccess(title: final title):
            await _shareIntake.dropLink(offer);
            if (!mounted) return;
            _goToTab(0);
            setState(() => _latestChanges++);
            _toast('Following ${title.isEmpty ? offer.name : title}.');
          case AlreadySubscribed(title: final title):
            _toast('Already following $title.');
          case SubscribeFailure(message: final message):
            _toast(message);
        }
      case 'save':
        final saved = await _shareIntake.savePage(offer);
        _onShare(saved, sourceApp: offer.sourceApp);
    }
  }

  /// Operator ruling 48: the "finish setup" line — shown while this app's
  /// recovery phrase has not been confirmed and kept, until dismissed.
  bool _showSetupReminder = false;

  Future<void> _checkSetupReminder() async {
    final custody = widget.services.backupCustody;
    if (custody == null) return;
    final show = await custody.readPhrase() == null &&
        !await custody.reminderDismissed();
    if (!mounted) return;
    setState(() => _showSetupReminder = show);
  }

  Future<void> _dismissSetupReminder() async {
    setState(() => _showSetupReminder = false);
    await widget.services.backupCustody?.dismissReminder();
  }

  @override
  void initState() {
    super.initState();
    unawaited(_checkSetupReminder());
    widget.shares?.addListener(_onSharesChanged);
    unawaited(_takeShares());
    _coordinator.onTranscribed = _onTranscribed;
    // Campaign 9 Phase 2 ("resume after restart"): shows the mini bar
    // paused at wherever playback last was, before anything is tapped —
    // see PlayerController.rehydrateLastPlayed's own doc for why this is
    // cheap (a DB read, never a real audio load).
    // It may write (clearing a stale id), so it waits for writesReady.
    final ready = widget.writesReady;
    if (ready == null) {
      _rehydrated = _player.rehydrateLastPlayed();
    } else {
      _rehydrated = ready.then((_) async {
        if (mounted) await _player.rehydrateLastPlayed();
      });
    }
    final host = widget.homeWidget;
    if (host != null && host.available) {
      host.onArrival = _onWidgetActions;
      unawaited(_rehydrated.then((_) {
        if (!mounted) return;
        final writer = _widgetWriter = WidgetSnapshotWriter(
          db: widget.db,
          profileId: widget.profile.id,
          player: _player,
          host: host,
          artworkFileFor: widget.services.localMlAvailable
              ? widget.services.artworkFileFor
              : null,
        );
        unawaited(writer.start());
      }));
      unawaited(_takeWidgetActions());
    }
  }

  @override
  void dispose() {
    widget.shares?.removeListener(_onSharesChanged);
    if (_coordinator.onTranscribed == _onTranscribed) {
      _coordinator.onTranscribed = null;
    }
    _widgetWriter?.dispose();
    final host = widget.homeWidget;
    if (host != null && host.onArrival == _onWidgetActions) {
      host.onArrival = null;
    }
    _host?.detach(_player);
    for (final r in _tabRoutes) {
      r.dispose();
    }
    _player.dispose();
    super.dispose();
  }

  /// The app-level host that shows this shell's bar over pushed pages.
  MiniPlayerHostState? _host;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final host = MiniPlayerHost.maybeOf(context);
    if (host == _host) return;
    _host?.detach(_player);
    _host = host?..attach(_player, (_) => _miniPlayerBar());
  }

  /// One bar, two places: inline above the tabs on the shell, and in the
  /// host over any pushed page.
  Widget _miniPlayerBar() => MiniPlayerBar(
        controller: _player,
        onOpenSyncedText: _openSyncedText,
        onCapture: _capture,
        onOpenCaptures: _openCaptures,
        onOpenQueue: _openQueue,
        onOpenChapters: _openChapters,
      );

  void _openModels() {
    // The web tier gets the honest explanation, never a manager whose
    // file operations would throw there.
    final Widget screen = widget.services.localMlAvailable
        ? ModelsScreen(
            store: widget.services.modelStore,
            registry: widget.services.registry,
            services: widget.services,
            databaseFile: widget.services.databaseFile,
            feedCheck: (widget.feedCheck?.scheduler.available ?? false)
                ? widget.feedCheck
                : null,
            db: widget.db,
            profileId: widget.profile.id,
            actions: _episodeActions,
          )
        : const WebTierModelsNotice();
    unawaited(_pushPage<void>(screen));
  }

  /// Backup & migrate, offered from the Library ⋮ (the _openModels
  /// pattern). A restore is full-replace, so the profile this shell holds
  /// may not exist afterwards — the screen pops `true` and we walk back to
  /// the profile picker rather than sit on a dangling id.
  Future<void> _openBackup() async {
    final restored = await _pushPage<bool>(BackupScreen(
        db: widget.db,
        profile: widget.profile,
        custody: widget.services.backupCustody,
        beforeRestore: widget.jobs.stopAll));
    if (restored == true) {
      await widget.jobs.reload();
      widget.onSwitchProfile();
      return;
    }
    await _checkSetupReminder();
  }

  /// Campaign 4 Phase 5: Trellis Echo, opened the same door-not-navigation
  /// way as [_openBackup]. Share stays native only — the web tier gets the
  /// screen with no share button rather than a dead one, the same law
  /// [_openModels] already follows for a different door.
  void _openEcho() {
    unawaited(_pushPage<void>(EchoScreen(
        db: widget.db,
        profile: widget.profile,
        shareImage: kIsWeb ? null : shareEchoImage)));
  }

  /// The player's Page door: the playing work's text in the reader, on
  /// Page, following the audio (1.5.5: one Page, not a separate view).
  Future<void> _openSyncedText() async {
    final work = _player.current;
    if (work == null) return;
    final episode = await widget.db.feedsDao.episodeOf(work.id);
    if (!mounted) return;
    await _workDoors.read(context, (work: work, episode: episode),
        openOnPage: true);
  }

  /// The study crown's "Capture" verb (Phase 2): one tap, a calm snackbar —
  /// no counter, no streak (ADR-0003 law 5). Campaign 9 Phase 1 adds the
  /// first discovery path for where a capture goes: a "View" action that
  /// opens the same captures list [_openCaptures] already wires to the
  /// bookmark door.
  Future<void> _capture() async {
    final id = await _player.capture();
    if (!mounted || id == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: const Text('Captured.'),
        // View is a convenience; the line lapses (conformance C14).
        persist: false,
        action: SnackBarAction(label: 'View', onPressed: _openCaptures),
      ));
  }

  void _openCaptures() {
    final work = _player.current;
    if (work == null) return;
    unawaited(_pushPage<void>(
        CapturesScreen(db: widget.db, controller: _player, work: work)));
  }

  void _openJobs() {
    unawaited(_pushPage<void>(JobsScreen(jobs: widget.jobs)));
  }

  /// The queue is a tab now (user: "I freaking hate how hidden the up
  /// next and up last screen is"), so the mini bar's door switches to it
  /// rather than stacking a second copy over the shell.
  void _openQueue() {
    // From the reader, the Queue tab is under it; from a page in the
    // Queue tab, its root is the queue.
    Navigator.of(context).popUntil((r) => r.isFirst);
    if (_tab != _queueTab) _goToTab(_queueTab);
    _popTabToRoot(_queueTab);
  }

  /// The episode actions and reader seams every list of works shares, so
  /// the Queue, the Library and History act and open the way Latest does.
  late final EpisodeActions _episodeActions = EpisodeActions(
    db: widget.db,
    profileId: widget.profile.id,
    player: _player,
    downloader: _downloadCoordinator,
    dsp: _dspCoordinator,
    transcriber: _coordinator,
    services: _repository.services,
    localMlAvailable: widget.services.localMlAvailable,
    openShow: _openShow,
  );

  /// The work page's "From …" for the Queue, the Library and History.
  Future<void> _openShow(BuildContext context, Feed feed) =>
      Navigator.of(context).push<void>(MaterialPageRoute(
          builder: (_) => FeedDetailScreen(
                db: widget.db,
                repository: _repository,
                feed: feed,
                playerController: _player,
                downloadCoordinator: _downloadCoordinator,
                dspCoordinator: _dspCoordinator,
                localMlAvailable: widget.services.localMlAvailable,
                readerDoors: _readerDoors,
                transcriber: _coordinator,
              )));

  ReaderDoors get _readerDoors => ReaderDoors(
        tts: widget.services.tts,
        localMlAvailable: widget.services.localMlAvailable,
        resolveSpeechEngine: widget.services.resolveSpeechEngine,
        lookupDefinition: widget.services.lookupDefinition,
        createSpeechTempFiles: widget.services.createSpeechTempFiles,
        player: _player,
        translation: widget.services.translation,
      );

  /// History, from the Queue bar: the queue is what plays next, history
  /// is what played. Built here, not in the Queue tab, because opening a
  /// row needs the reader's and the episode actions' whole kit.
  Future<void> _openHistory() => _pushPage<void>(HistoryScreen(
        doors: SearchDoors(
          db: widget.db,
          profile: widget.profile,
          actions: _episodeActions,
          readerDoors: _readerDoors,
        ),
      ));

  /// Subscriptions, from the Library's bar (Latest opens its own): inside
  /// the tab. Latest reads again after, since a follow or an unfollow
  /// changes it.
  Future<void> _openSubscriptions(BuildContext context) async {
    await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => FeedsScreen(
              db: widget.db,
              repository: _repository,
              profile: widget.profile,
              localMlAvailable: widget.services.localMlAvailable,
              playerController: _player,
              downloadCoordinator: _downloadCoordinator,
              dspCoordinator: _dspCoordinator,
              readerDoors: _readerDoors,
              transcriber: _coordinator,
            )));
    if (mounted) setState(() => _latestChanges++);
  }

  /// The + Add sheet's "Subscribe to a feed": the same screen Latest's
  /// empty state opens, inside the tab it was opened from.
  Future<void> _subscribe(BuildContext context) async {
    final followed = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => SubscribeScreen(
            repository: _repository, profileId: widget.profile.id)));
    if (followed == true && mounted) setState(() => _latestChanges++);
  }

  /// The audiobook door (Campaign 7, ADR-0013) — null when the door was
  /// never constructed (the web tier), which also hides the option on
  /// [LibraryScreen] by construction.
  Future<int?> Function(BuildContext)? get _onImportAudiobook {
    final gateway = _audiobookGateway;
    final repository = _audiobookRepository;
    if (gateway == null || repository == null) return null;
    return (ctx) => pickAndImportAudiobook(
          ctx,
          profileId: widget.profile.id,
          gateway: gateway,
          repository: repository,
        );
  }

  /// Deletes an audiobook's copied files (ADR-0013) — the storage half of
  /// removing it; [LibraryScreen] pairs this with its own DB delete.
  void _deleteAudiobookFiles(int workId) {
    final dir = widget.services.audiobookDirFor(workId);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  void _openChapters() {
    final work = _player.current;
    final files = _player.currentAudiobookFiles;
    if (work == null || files == null) return;
    unawaited(_pushPage<void>(ChaptersScreen(
      controller: _player,
      work: work,
      files: files,
      computeChapters: (files) =>
          chaptersFor(files, readAudiobookChapterPrefix),
    )));
  }

  /// A tab's root screen.
  Widget _tabRoot(int tab) => switch (tab) {
        0 => RiverScreen(
            active: _tab == 0,
            changes: _latestChanges,
            onOpenWork: (id) => unawaited(_refetchOnOpen(id)),
            db: widget.db,
            profile: widget.profile,
            repository: _repository,
            playerController: _player,
            coordinator: _coordinator,
            downloadCoordinator: _downloadCoordinator,
            dspCoordinator: _dspCoordinator,
            localMlAvailable: widget.services.localMlAvailable,
            resolveSpeechEngine: widget.services.resolveSpeechEngine,
            lookupDefinition: widget.services.lookupDefinition,
            createSpeechTempFiles: widget.services.createSpeechTempFiles,
            translation: widget.services.translation,
            tts: widget.services.tts),
        _queueTab => QueueScreen(
            db: widget.db,
            profile: widget.profile,
            player: _player,
            actions: _episodeActions,
            readerDoors: _readerDoors,
            onOpenHistory: _openHistory),
        _libraryTab => LibraryScreen(
            db: widget.db,
            profile: widget.profile,
            onSwitchProfile: widget.onSwitchProfile,
            onOpenModels: _openModels,
            onOpenBackup: _openBackup,
            onSubscribe: _subscribe,
            onOpenSubscriptions: _openSubscriptions,
            fetcher: widget.fetcher,
            tts: widget.services.tts,
            lane: widget.services.webFetchLane,
            localMlAvailable: widget.services.localMlAvailable,
            resolveSpeechEngine: widget.services.resolveSpeechEngine,
            lookupDefinition: widget.services.lookupDefinition,
            createSpeechTempFiles: widget.services.createSpeechTempFiles,
            player: _player,
            translation: widget.services.translation,
            actions: _episodeActions,
            onImportAudiobook: _onImportAudiobook,
            onDeleteAudiobookFiles: widget.services.localMlAvailable
                ? _deleteAudiobookFiles
                : null),
        _ => CoursesScreen(
            db: widget.db,
            profile: widget.profile,
            onOpenEcho: _openEcho,
            localMlAvailable: widget.services.localMlAvailable,
          ),
      };

  Widget _tabStack(int tab) {
    if (!_builtTabs.contains(tab)) return const SizedBox.shrink();
    return Navigator(
      key: _tabNavigators[tab],
      observers: [_tabRoutes[tab]],
      pages: [
        MaterialPage<void>(
          key: ValueKey('tab-$tab'),
          child: KeyedSubtree(
              key: ValueKey(_tabEpochs[tab]), child: _tabRoot(tab)),
        ),
      ],
      // A tab's root page is never removed; pages above it are pushed.
      onDidRemovePage: (_) {},
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // System back closes the page in view in the tab in view; at that
      // tab's root it leaves the app as before. One handler for all tabs,
      // since all four share this route: a hidden tab's pages are left be.
      body: PopScope(
        canPop: !_tabCanPop,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_tabNavigator(_tab)?.maybePop());
        },
        child: IndexedStack(
          index: _tab,
          children: [for (var i = 0; i < 4; i++) _tabStack(i)],
        ),
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_showSetupReminder)
            _SetupReminder(
                onOpen: _openBackup, onDismiss: _dismissSetupReminder),
          _JobsStrip(jobs: widget.jobs, onOpen: _openJobs),
          // While a page is pushed over the shell the host shows the bar;
          // this one steps aside so the shell beneath isn't squeezed by two.
          if (_host case final host?)
            ListenableBuilder(
              listenable: host.routes,
              builder: (_, _) => host.routes.pageOverRoot
                  ? const SizedBox.shrink()
                  : _miniPlayerBar(),
            )
          else
            _miniPlayerBar(),
          NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: _selectTab,
            destinations: const [
              // "Latest", the industry's word, not the coined "River"
              // (operator naming ruling): every item from every followed
              // feed, newest first, kept for good (ADR-0019); keeping one
              // puts it in the Library.
              NavigationDestination(
                icon: Icon(Icons.dynamic_feed_outlined),
                selectedIcon: Icon(Icons.dynamic_feed),
                label: 'Latest',
              ),
              // "Queue", not the coined "Up Next": what plays after this,
              // in the order the listener chose.
              NavigationDestination(
                icon: Icon(Icons.queue_music_outlined),
                selectedIcon: Icon(Icons.queue_music),
                label: 'Queue',
              ),
              NavigationDestination(
                icon: Icon(Icons.local_library_outlined),
                selectedIcon: Icon(Icons.local_library),
                label: 'Library',
              ),
              NavigationDestination(
                icon: Icon(Icons.school_outlined),
                selectedIcon: Icon(Icons.school),
                label: 'Courses',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Tells the shell when a tab's pages change, so system back knows
/// whether the tab in view has a page to close.
class _TabRoutes extends NavigatorObserver with ChangeNotifier {
  bool _disposed = false;

  // A tab's pages pop as the shell goes (a switch of reader).
  void _changed() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) notifyListeners();
      });

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _changed();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _changed();

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _changed();

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _changed();
}

/// The door to the Jobs screen, on every tab, present only while some job
/// exists: one line of counts, no badge, no colour beyond the theme's.
class _JobsStrip extends StatelessWidget {
  final JobCenter jobs;
  final VoidCallback onOpen;
  const _JobsStrip({required this.jobs, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: jobs,
      builder: (context, _) {
        final counts = jobs.counts;
        if (counts.total == 0) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Material(
          color: theme.colorScheme.surfaceContainerHigh,
          child: InkWell(
            key: const Key('jobs-strip'),
            onTap: onOpen,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Icon(
                        counts.running > 0
                            ? Icons.downloading
                            : Icons.pause_circle_outline,
                        size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(jobsSummary(counts),
                          style: theme.textTheme.bodyMedium),
                    ),
                    Text('See jobs',
                        style: theme.textTheme.labelLarge
                            ?.copyWith(color: theme.colorScheme.primary)),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One calm line above the tabs, never a modal and never red: what is
/// unfinished, the door to finish it, and a way to say "not now" for good.
class _SetupReminder extends StatelessWidget {
  final VoidCallback onOpen;
  final VoidCallback onDismiss;
  const _SetupReminder({required this.onOpen, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      key: const Key('setup-reminder'),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              "Finish setup: save your recovery phrase, so this app’s "
              'backups can be opened.',
              style: theme.textTheme.bodyMedium,
            ),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  key: const Key('setup-reminder-dismiss'),
                  onPressed: onDismiss,
                  child: const Text('Dismiss'),
                ),
                TextButton(
                  key: const Key('setup-reminder-open'),
                  onPressed: onOpen,
                  child: const Text('Set up'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The choice a shared feed earns: follow it, or keep the page itself.
/// Both are plain buttons at thumb height; dismissing saves nothing.
class _SubscribeSheet extends StatelessWidget {
  final ShareOffersFeed offer;
  const _SubscribeSheet({required this.offer});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(offer.pageUrl.host, style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            Text('This has a feed. Follow it, and its new posts come to '
                'Latest.',
                style: theme.textTheme.bodyMedium),
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const Key('share-subscribe'),
              onPressed: () => Navigator.pop(context, 'subscribe'),
              icon: const Icon(Icons.rss_feed),
              label: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('Subscribe to ${offer.name}',
                    textAlign: TextAlign.center),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const Key('share-save-page'),
              onPressed: () => Navigator.pop(context, 'save'),
              icon: const Icon(Icons.bookmark_add_outlined),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Save this page'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
