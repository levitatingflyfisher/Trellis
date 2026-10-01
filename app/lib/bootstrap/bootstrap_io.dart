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
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;
import 'package:sqlite3/sqlite3.dart' show sqlite3;

import '../db/database.dart';
import '../features/reader/speech/speech_temp_files.dart';
import '../net/io_fetcher.dart';
import '../services/device_services.dart';

/// drift_flutter's native convention: documents-dir/NAME.sqlite, opened
/// the way its `driftDatabase` opens it, plus a read pool, which it has no
/// option for. [readPool] is how many reading connections run beside the
/// writer: the app's one, so a search never queues behind a refresh's
/// write transaction (1.5.4). The background check (ADR-0018) only
/// writes and passes none.
AppDatabase createDb({int readPool = 1}) =>
    AppDatabase(DatabaseConnection.delayed(Future(() async {
      // sqlite3's temporary files: the system default may be out of the
      // sandbox's reach. A process-wide setting, so the readers get it too.
      sqlite3.tempDirectory ??= (await getTemporaryDirectory()).path;
      return openNativeConnection(
          databaseFileIn(await getApplicationDocumentsDirectory()),
          readPool: readPool);
    })));

/// The connection [createDb] opens, on a background isolate, with
/// [readPool] reading isolates beside it. drift sends SELECTs outside a
/// transaction to the readers and everything else to the writer; under
/// WAL a reader sees the last commit and never waits for a writer.
/// (drift_flutter's old-Android workaround is for API levels below the
/// app's minimum of 24.)
DatabaseConnection openNativeConnection(File file, {int readPool = 1}) =>
    NativeDatabase.createBackgroundConnection(file,
        setup: configureConnection, readPool: readPool);

/// Runs on every native connection, readers included, before drift reads
/// the schema version, so a second connection (the background feed
/// check, ADR-0018) waits for the first instead of failing with "database
/// is locked" mid-migration. AppDatabase's beforeOpen sets the same
/// timeout again, but only after the migrations, which is too late for an
/// upgrade. WAL is what lets a reader run beside a write; it persists in
/// the file, and asking again once it is set changes nothing.
void configureConnection(CommonDatabase db) {
  db.execute('PRAGMA busy_timeout = 15000');
  db.execute('PRAGMA journal_mode = WAL');
}

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
  final services = servicesFor(
    await getApplicationSupportDirectory(),
    databaseFile: databaseFileIn(await getApplicationDocumentsDirectory()),
  );
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
/// Reached by name only, so `res/raw/keep.xml` must list it or the release
/// shrinker strips it and the first playback notification kills the app.
const audioNotificationIcon = 'drawable/ic_notification';

Future<void> initAudioBackground() => JustAudioBackground.init(
  androidNotificationChannelId: 'com.openhearth.trellis.channel.audio',
  androidNotificationChannelName: 'Trellis playback',
  androidNotificationIcon: audioNotificationIcon,
  androidNotificationOngoing: true,
);
