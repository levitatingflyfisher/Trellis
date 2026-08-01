import 'package:comms_core/comms_core.dart';
import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../../services/device_services.dart';
import '../backup/backup_screen.dart';
import '../feeds/feeds_repository.dart';
import '../library/library_screen.dart';
import '../models/models_screen.dart';
import '../player/episode_player.dart';
import '../player/karaoke_screen.dart';
import '../player/mini_player_bar.dart';
import '../player/player_controller.dart';
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
  const HomeShell(
      {super.key,
      required this.db,
      required this.profile,
      required this.onSwitchProfile,
      required this.fetcher,
      required this.createPlayer,
      required this.services});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  late final FeedsRepository _repository =
      FeedsRepository(db: widget.db, fetcher: widget.fetcher);
  late final PlayerController _player = PlayerController(
      db: widget.db,
      profileId: widget.profile.id,
      createPlayer: widget.createPlayer);
  late final TranscribeCoordinator _coordinator = TranscribeCoordinator(
      db: widget.db,
      services: widget.services,
      // A transcript landing mid-playback opens the karaoke door live.
      onTranscribed: (workId) => _player.reloadAlignments(workId));

  @override
  void initState() {
    super.initState();
    _coordinator.restore();
  }

  @override
  void dispose() {
    _coordinator.dispose();
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
            databaseFile: widget.services.databaseFile)
        : const WebTierModelsNotice();
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  /// Backup & migrate, offered from the Courses tab (the _openModels
  /// pattern). A restore is full-replace, so the profile this shell holds
  /// may not exist afterwards — the screen pops `true` and we walk back to
  /// the profile picker rather than sit on a dangling id.
  Future<void> _openBackup() async {
    final restored = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
            builder: (_) =>
                BackupScreen(db: widget.db, profile: widget.profile)));
    if (restored == true) widget.onSwitchProfile();
  }

  void _openSyncedText() {
    final work = _player.current;
    if (work == null) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) =>
            KaraokeScreen(db: widget.db, controller: _player, work: work)));
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
            createSpeechTempFiles: widget.services.createSpeechTempFiles),
        1 => RiverScreen(
            db: widget.db,
            profile: widget.profile,
            repository: _repository,
            playerController: _player,
            coordinator: _coordinator,
            localMlAvailable: widget.services.localMlAvailable,
            resolveSpeechEngine: widget.services.resolveSpeechEngine,
            createSpeechTempFiles: widget.services.createSpeechTempFiles),
        _ => CoursesScreen(
            db: widget.db,
            profile: widget.profile,
            onOpenBackup: _openBackup,
            localMlAvailable: widget.services.localMlAvailable),
      },
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MiniPlayerBar(
              controller: _player, onOpenSyncedText: _openSyncedText),
          NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: const [
              NavigationDestination(
                  icon: Icon(Icons.local_library_outlined),
                  selectedIcon: Icon(Icons.local_library),
                  label: 'Library'),
              NavigationDestination(
                  icon: Icon(Icons.waves_outlined),
                  selectedIcon: Icon(Icons.waves),
                  label: 'River'),
              NavigationDestination(
                  icon: Icon(Icons.school_outlined),
                  selectedIcon: Icon(Icons.school),
                  label: 'Courses'),
            ],
          ),
        ],
      ),
    );
  }
}
