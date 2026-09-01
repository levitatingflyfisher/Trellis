import 'package:comms_core/comms_core.dart';
import 'package:flutter/material.dart';
import 'package:openhearth_design/openhearth_design.dart';

import 'bootstrap/boot_guard.dart';
import 'bootstrap/bootstrap.dart';
import 'db/database.dart';
import 'features/player/episode_player.dart';
import 'features/player/just_audio_player.dart';
import 'features/profiles/home_flow.dart';
import 'features/settings/theme_preference.dart';
import 'net/io_fetcher.dart';
import 'services/device_services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // EVERY await below is on the critical path to the first frame, not just
  // to its own feature. 1.4.0 proved what that costs: initAudioBackground()
  // threw on a host-activity misconfiguration, the throw escaped main(),
  // runApp() never ran, and the app sat on its launch logo forever with
  // nothing on screen to say why. So each step is best-effort now — it may
  // fail, loudly and visibly, but it may not take the boot with it
  // (bootstrap/boot_guard.dart).
  final bootNotes = <String>[];

  // Campaign 9 Phase 2e (ADR-0015 Decision 3): must run before the app's
  // single AudioPlayer is ever constructed — a real call on Android/iOS,
  // a no-op on the web tier (bootstrap_web.dart's own stub).
  await bestEffort<void>(
    what: 'Lock-screen controls',
    run: initAudioBackground,
    orElse: () {},
    notes: bootNotes,
  );

  // All platform truth lives behind the bootstrap boundary (bootstrap.dart):
  // native gets path_provider dirs + DeviceServices.real + drift's file db;
  // the web build gets drift-on-wasm and web-safe services. No dart:io here.
  //
  // services is awaited FIRST: on the web tier it carries the boot-time
  // Skein probe (webFetchLane), and the fetcher must be built knowing
  // that lane rather than always defaulting to direct.
  final services = await bestEffort<DeviceServices>(
    what: 'Device storage',
    run: createServices,
    orElse: detachedServices,
    notes: bootNotes,
  );

  // Read before the first frame, so a chosen theme never flashes the
  // other one first, but only within a short deadline: a slow database
  // open must not keep the first frame from painting (1.4.0). On a slow
  // start this is null and TrellisApp applies the choice when it arrives.
  final db = createDb();
  final theme = await ThemePreferenceController.readBeforeFirstFrame(db);

  runApp(TrellisApp(
    db: db,
    fetcher: createFetcher(lane: services.webFetchLane),
    services: services,
    bootNotes: bootNotes,
    initialTheme: theme,
  ));
}

/// P3 shell (proposal-2 §14): profiles → Library/River shell → reader,
/// player and the transcription flow over the one content spine. Plain
/// Navigator; the db, the HTTP seam, the audio seam and the device stack
/// are passed down — tests inject `AppDatabase.forTesting`, a
/// ScriptedFetcher, a FakeEpisodePlayer and fake DeviceServices, so no test
/// ever touches a socket or a platform channel.
class TrellisApp extends StatefulWidget {
  final AppDatabase db;
  final HttpFetcher fetcher;
  final EpisodePlayer Function() createPlayer;
  final DeviceServices services;

  /// What the boot could not bring up, surfaced above the app rather than
  /// swallowed. Empty on an ordinary start.
  final List<String> bootNotes;

  /// The theme choice read before `runApp`; when null (widget tests) the
  /// app reads it itself on its first frame.
  final OhThemeModePreference? initialTheme;

  TrellisApp(
      {super.key,
      required this.db,
      HttpFetcher? fetcher,
      EpisodePlayer Function()? createPlayer,
      DeviceServices? services,
      this.bootNotes = const [],
      this.initialTheme})
      : fetcher = fetcher ?? IoHttpFetcher(),
        createPlayer = createPlayer ?? (() => JustAudioEpisodePlayer()),
        services = services ?? DeviceServices.detached();

  @override
  State<TrellisApp> createState() => _TrellisAppState();
}

class _TrellisAppState extends State<TrellisApp> {
  late final ThemePreferenceController _theme = ThemePreferenceController(
      widget.db, widget.initialTheme ?? OhThemeModePreference.system);

  @override
  void initState() {
    super.initState();
    if (widget.initialTheme == null) _theme.load();
  }

  @override
  void dispose() {
    _theme.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ThemePreferenceScope(
      controller: _theme,
      child: ListenableBuilder(
        listenable: _theme,
        builder: (context, _) => MaterialApp(
          title: 'Trellis',
          // The ribbon overlapped the appbar's profile chip (visual tour).
          debugShowCheckedModeBanner: false,
          // The wall by day and at dusk (proposal-2 §12): hearth
          // terracotta on warm linen, from the canonical tokens (C1). Light,
          // dark or follow the phone, the person's choice (fleet ruling).
          theme: OhTheme.light(),
          darkTheme: OhTheme.hearthDark(),
          themeMode: _theme.value.themeMode,
          home: BootNotice(
            notes: widget.bootNotes,
            child: HomeFlow(
                db: widget.db,
                fetcher: widget.fetcher,
                createPlayer: widget.createPlayer,
                services: widget.services),
          ),
        ),
      ),
    );
  }
}
