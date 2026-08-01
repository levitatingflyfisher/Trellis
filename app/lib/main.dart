import 'package:comms_core/comms_core.dart';
import 'package:flutter/material.dart';
import 'package:openhearth_design/openhearth_design.dart';

import 'bootstrap/bootstrap.dart';
import 'db/database.dart';
import 'features/player/episode_player.dart';
import 'features/player/just_audio_player.dart';
import 'features/profiles/home_flow.dart';
import 'net/io_fetcher.dart';
import 'services/device_services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Campaign 9 Phase 2e (ADR-0015 Decision 3): must run before the app's
  // single AudioPlayer is ever constructed — a real call on Android/iOS,
  // a no-op on the web tier (bootstrap_web.dart's own stub).
  await initAudioBackground();
  // All platform truth lives behind the bootstrap seam (bootstrap.dart):
  // native gets path_provider dirs + DeviceServices.real + drift's file db;
  // the web build gets drift-on-wasm and web-safe services. No dart:io here.
  //
  // services is awaited FIRST: on the web tier it carries the boot-time
  // Skein probe (webFetchLane), and the fetcher must be built knowing
  // that lane rather than always defaulting to direct.
  final services = await createServices();
  runApp(TrellisApp(
    db: createDb(),
    fetcher: createFetcher(lane: services.webFetchLane),
    services: services,
  ));
}

/// P3 shell (proposal-2 §14): profiles → Library/River shell → reader,
/// player and the transcription flow over the one content spine. Plain
/// Navigator; the db, the HTTP seam, the audio seam and the device stack
/// are passed down — tests inject `AppDatabase.forTesting`, a
/// ScriptedFetcher, a FakeEpisodePlayer and fake DeviceServices, so no test
/// ever touches a socket or a platform channel.
class TrellisApp extends StatelessWidget {
  final AppDatabase db;
  final HttpFetcher fetcher;
  final EpisodePlayer Function() createPlayer;
  final DeviceServices services;
  TrellisApp(
      {super.key,
      required this.db,
      HttpFetcher? fetcher,
      EpisodePlayer Function()? createPlayer,
      DeviceServices? services})
      : fetcher = fetcher ?? IoHttpFetcher(),
        createPlayer = createPlayer ?? (() => JustAudioEpisodePlayer()),
        services = services ?? DeviceServices.detached();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Trellis',
      // The ribbon overlapped the appbar's profile chip (visual tour).
      debugShowCheckedModeBanner: false,
      // The wall by day and at dusk (proposal-2 §12): the fleet tri-theme,
      // hearth terracotta on warm linen, from the canonical tokens (C1).
      theme: OhTheme.light(),
      darkTheme: OhTheme.hearthDark(),
      home: HomeFlow(
          db: db,
          fetcher: fetcher,
          createPlayer: createPlayer,
          services: services),
    );
  }
}
