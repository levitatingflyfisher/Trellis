import 'dart:async';

import 'package:comms_core/comms_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../../services/device_services.dart';
import '../backup/backup_screen.dart';
import '../dsp/dsp_coordinator.dart';
import '../echo/echo_screen.dart';
import '../feeds/episode_download_coordinator.dart';
import '../feeds/feeds_repository.dart';
import '../intake/audiobook_import.dart';
import '../intake/audiobook_import_screen.dart';
import '../intake/audiobook_picker_gateway.dart';
import '../library/library_screen.dart';
import '../models/models_screen.dart';
import '../player/accelerometer_samples.dart';
import '../player/audiobook_chapters.dart';
import '../player/captures_screen.dart';
import '../player/chapters_screen.dart';
import '../player/episode_player.dart';
import '../player/karaoke_screen.dart';
import '../player/mini_player_bar.dart';
import '../player/player_controller.dart';
import '../player/queue_screen.dart';
import '../river/river_screen.dart';
import '../study/courses_screen.dart';
import '../transcribe/transcribe_coordinator.dart';

/// One reader's shell: Library, River and Courses tabs over a single
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
  });

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  late final FeedsRepository _repository = FeedsRepository(
    db: widget.db,
    fetcher: widget.fetcher,
    services: widget.services,
  );
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
  late final TranscribeCoordinator _coordinator = TranscribeCoordinator(
    db: widget.db,
    services: widget.services,
    // A transcript landing mid-playback opens the karaoke door live, and
    // backfills the sentence-snap on any capture taken before it existed
    // (the study crown, Phase 2).
    onTranscribed: (workId) {
      _player.reloadAlignments(workId);
      unawaited(widget.db.capturesDao.backfillForWork(workId));
    },
  );

  /// The standalone Download door (Campaign 6) — null on the web tier,
  /// same law as `_player`'s localAudioFileFor: never construct a flow
  /// that would call a real dart:io method where none works.
  late final EpisodeDownloadCoordinator? _downloadCoordinator =
      widget.services.localMlAvailable
      ? EpisodeDownloadCoordinator(services: widget.services)
      : null;

  /// The offline DSP preprocess (Campaign 6, ADR-0012) — same web-tier
  /// null law as `_downloadCoordinator`, since it shares the same
  /// dart:io/ffmpeg dependency.
  late final DspCoordinator? _dspCoordinator = widget.services.localMlAvailable
      ? DspCoordinator(db: widget.db, services: widget.services)
      : null;

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

  @override
  void initState() {
    super.initState();
    _coordinator.restore();
    _dspCoordinator?.restore();
    // Campaign 9 Phase 2 ("resume after restart"): shows the mini bar
    // paused at wherever playback last was, before anything is tapped —
    // see PlayerController.rehydrateLastPlayed's own doc for why this is
    // cheap (a DB read, never a real audio load).
    _player.rehydrateLastPlayed();
  }

  @override
  void dispose() {
    _coordinator.dispose();
    _downloadCoordinator?.dispose();
    _dspCoordinator?.dispose();
    _player.dispose();
    super.dispose();
  }

  void _openModels() {
    // The web tier gets the honest explanation, never a manager whose
    // file operations would throw there.
    final Widget screen = widget.services.localMlAvailable
        ? ModelsScreen(
            store: widget.services.modelStore,
            registry: widget.services.registry,
            services: widget.services,
            databaseFile: widget.services.databaseFile,
          )
        : const WebTierModelsNotice();
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  /// Backup & migrate, offered from the Courses tab (the _openModels
  /// pattern). A restore is full-replace, so the profile this shell holds
  /// may not exist afterwards — the screen pops `true` and we walk back to
  /// the profile picker rather than sit on a dangling id.
  Future<void> _openBackup() async {
    final restored = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => BackupScreen(db: widget.db, profile: widget.profile),
      ),
    );
    if (restored == true) widget.onSwitchProfile();
  }

  /// Campaign 4 Phase 5: Trellis Echo, opened the same door-not-navigation
  /// way as [_openBackup]. Share stays native only — the web tier gets the
  /// screen with no share button rather than a dead one, the same law
  /// [_openModels] already follows for a different door.
  void _openEcho() {
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => EchoScreen(
            db: widget.db,
            profile: widget.profile,
            shareImage: kIsWeb ? null : shareEchoImage)));
  }

  void _openSyncedText() {
    final work = _player.current;
    if (work == null) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => KaraokeScreen(
            db: widget.db,
            controller: _player,
            work: work,
            tts: widget.services.tts,
            resolveSpeechEngine: widget.services.resolveSpeechEngine,
            createSpeechTempFiles: widget.services.createSpeechTempFiles,
            resolveTranslator: widget.services.resolveTranslator,
            availableTranslationTargets:
                widget.services.availableTranslationTargets)));
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
        action: SnackBarAction(label: 'View', onPressed: _openCaptures),
      ));
  }

  void _openCaptures() {
    final work = _player.current;
    if (work == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            CapturesScreen(db: widget.db, controller: _player, work: work),
      ),
    );
  }

  void _openQueue() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => QueueScreen(db: widget.db, profile: widget.profile),
      ),
    );
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
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChaptersScreen(
          controller: _player,
          work: work,
          files: files,
          computeChapters: (files) =>
              chaptersFor(files, readAudiobookChapterPrefix),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: switch (_tab) {
        0 => LibraryScreen(
            db: widget.db,
            profile: widget.profile,
            onSwitchProfile: widget.onSwitchProfile,
            onOpenModels: _openModels,
            fetcher: widget.fetcher,
            tts: widget.services.tts,
            lane: widget.services.webFetchLane,
            localMlAvailable: widget.services.localMlAvailable,
            resolveSpeechEngine: widget.services.resolveSpeechEngine,
            lookupDefinition: widget.services.lookupDefinition,
            createSpeechTempFiles: widget.services.createSpeechTempFiles,
            player: _player,
            resolveTranslator: widget.services.resolveTranslator,
            availableTranslationTargets:
                widget.services.availableTranslationTargets,
            onImportAudiobook: _onImportAudiobook,
            onDeleteAudiobookFiles: widget.services.localMlAvailable
                ? _deleteAudiobookFiles
                : null),
        1 => RiverScreen(
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
            resolveTranslator: widget.services.resolveTranslator,
            availableTranslationTargets:
                widget.services.availableTranslationTargets),
        _ => CoursesScreen(
          db: widget.db,
          profile: widget.profile,
          onOpenBackup: _openBackup,
          onOpenEcho: _openEcho,
          localMlAvailable: widget.services.localMlAvailable,
        ),
      },
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MiniPlayerBar(
            controller: _player,
            onOpenSyncedText: _openSyncedText,
            onCapture: _capture,
            onOpenCaptures: _openCaptures,
            onOpenQueue: _openQueue,
            onOpenChapters: _openChapters,
          ),
          NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.local_library_outlined),
                selectedIcon: Icon(Icons.local_library),
                label: 'Library',
              ),
              NavigationDestination(
                icon: Icon(Icons.waves_outlined),
                selectedIcon: Icon(Icons.waves),
                label: 'River',
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
