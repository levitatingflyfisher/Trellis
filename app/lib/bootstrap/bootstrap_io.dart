/// The native side of the bootstrap seam: exactly what main() wired before
/// the seam existed — the app-support dir roots the P3 device stack, drift
/// keeps its file database under the documents dir, DeviceServices.real
/// supplies the platform truth.
///
/// The path_provider calls live only in the thin async wrappers; the
/// channel-free cores ([servicesFor], [databaseFileIn]) carry the wiring
/// decisions and are what the bootstrap tests pin.
library;

import 'dart:io';

import 'package:comms_core/comms_core.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../db/database.dart';
import '../features/reader/speech/speech_temp_files.dart';
import '../net/io_fetcher.dart';
import '../services/device_services.dart';

/// drift_flutter's native convention: documents-dir/NAME.sqlite.
AppDatabase createDb() => AppDatabase(driftDatabase(name: 'trellis'));

/// Where drift keeps the database — named so the storage panel can weigh
/// the real file, not a guess.
Future<File?> databaseFile() async =>
    databaseFileIn(await getApplicationDocumentsDirectory());

/// Channel-free core of [databaseFile]: mirrors drift_flutter's naming law.
File databaseFileIn(Directory documentsDir) =>
    File(p.join(documentsDir.path, 'trellis.sqlite'));

/// The P3 device stack rooted in app support (path_provider), database file
/// threaded through for the storage panel. Also sweeps [speechTempDir]
/// (ADR-0006): a session killed mid-speech leaves WAVs behind with no
/// chance to run its own stop()/dispose() cleanup — this is app start's
/// one shot to reclaim them. Real disk IO, so it belongs here in the async
/// wrapper, never in [servicesFor]'s channel-free core, and never on the
/// web side (dart:io Directory operations throw under dart2js).
Future<DeviceServices> createServices() async {
  final services = servicesFor(await getApplicationSupportDirectory(),
      databaseFile: databaseFileIn(await getApplicationDocumentsDirectory()));
  await sweepStaleSpeechTempFiles(services.speechTempDir);
  return services;
}

/// Channel-free core of [createServices].
DeviceServices servicesFor(Directory supportDir, {File? databaseFile}) =>
    DeviceServices.real(supportDir, databaseFile: databaseFile);

/// The last resort when [createServices] throws — a dead path_provider
/// channel, a full disk. main() runs the app on this rather than not at
/// all (boot_guard.dart): the P3 flows that need real paths will say so,
/// which beats a launch logo that says nothing. Native platforms can use
/// the placeholder stack directly; the web side overrides this because
/// [DeviceServices.detached]'s Directory.systemTemp throws under dart2js.
DeviceServices detachedServices() => DeviceServices.detached();

/// The dart:io HTTP stack, redirect hops SSRF-re-checked (io_fetcher.dart).
/// [lane] is a web-tier-only concept (Skein exists to dissolve the
/// browser's CORS wall); native apps fetch directly regardless, so it is
/// accepted only to keep this signature identical to the web side's.
HttpFetcher createFetcher({WebFetchLane lane = WebFetchLane.direct}) =>
    IoHttpFetcher();

/// Campaign 9 Phase 2e (ADR-0015 Decision 3): the lock-screen/pull-down-
/// tray media session — must run before the app's own single AudioPlayer
/// is ever constructed (just_audio_background's own documented ordering;
/// [PlayerController] never builds one until playback first starts, well
/// after this call, so `main()` calling this ahead of `runApp` is early
/// enough). `androidNotificationIcon` names Phase 8's own asset
/// (`drawable-*dpi/ic_notification.png`) — generated ahead of this work
/// landing, an orphan until now.
///
/// Android/iOS only; the web side's own [createServices]-adjacent stub
/// (bootstrap_web.dart) is a no-op, so `main()` can call this name
/// unconditionally on every platform without a check of its own.
Future<void> initAudioBackground() => JustAudioBackground.init(
      androidNotificationChannelId: 'com.openhearth.trellis.channel.audio',
      androidNotificationChannelName: 'Trellis playback',
      androidNotificationIcon: 'drawable/ic_notification',
      androidNotificationOngoing: true,
    );
