/// The IO side of the conditional bootstrap (bootstrap.dart resolves here
/// on the VM): the pieces main() wires on native platforms, tested without
/// touching a platform channel — the channel-bound wrappers (path_provider)
/// stay thin over these.
library;

import 'dart:io';

import 'package:dio/dio.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:trellis/bootstrap/bootstrap.dart';
import 'package:trellis/features/storage/recently_deleted.dart';
import 'package:trellis/features/storage/work_storage.dart' show StoredKind;
import 'package:trellis/features/models/model_store.dart';
import 'package:trellis/features/transcribe/decoder.dart';
import 'package:trellis/features/transcribe/foreground_gate.dart';
import 'package:trellis/features/transcribe/transcribe_executor.dart';
import 'package:trellis/net/io_fetcher.dart';

void main() {
  test('databaseFileIn mirrors drift_flutter: documents-dir/trellis.sqlite',
      () {
    final f = databaseFileIn(Directory(p.join('some', 'docs')));
    expect(f.path, p.join('some', 'docs', 'trellis.sqlite'));
  });

  test('servicesFor wires the real device stack rooted at the support dir',
      () {
    final dir = Directory.systemTemp.createTempSync('trellis-bootstrap');
    addTearDown(() => dir.deleteSync(recursive: true));
    final dbFile = File(p.join(dir.path, 'trellis.sqlite'));

    final s = servicesFor(dir, databaseFile: dbFile);

    expect(s.supportDir.path, dir.path);
    expect(s.databaseFile, same(dbFile));
    // The real stack main() has always wired: models under the support dir,
    // work off the UI isolate.
    expect(s.modelStore, isA<DiskModelStore>());
    expect((s.modelStore as DiskModelStore).baseDir.path,
        '${dir.path}/models');
    expect(s.executor, isA<IsolateTranscribeExecutor>());
    // The host test runner is not Android:
    expect(s.decoder, isA<WavPassthroughDecoder>());
    expect(s.foregroundGate, isA<NoopJobForegroundGate>());
  });

  test('start-up lets go of Recently deleted past 30 days, past a broken '
      'file', () async {
    final dir = Directory.systemTemp.createTempSync('trellis-bootstrap');
    addTearDown(() => dir.deleteSync(recursive: true));
    final s = servicesFor(dir);
    final bin = s.recentlyDeleted!;
    DeletedSnapshot snap(String id, int daysAgo) => DeletedSnapshot(
        id: id,
        workId: 1,
        workTitle: 'W',
        kind: StoredKind.transcript,
        lang: null,
        deletedAt: DateTime.now().subtract(Duration(days: daysAgo)),
        bytes: 1);
    await bin.save(snap('old', 31), const {});
    await bin.save(snap('new', 29), const {});
    File(p.join(bin.dir.path, 'junk.json')).writeAsStringSync('[');

    await purgeRecentlyDeleted(s);

    expect([for (final x in await bin.list()) x.id], ['new']);
  });

  test('start-up tidies the model store: prunes what the registry no '
      'longer pins, attempts no download, and never throws', () async {
    final dir = Directory.systemTemp.createTempSync('trellis-bootstrap');
    addTearDown(() => dir.deleteSync(recursive: true));
    final s = servicesFor(dir);
    // ADR-0003: no egress at boot without a user gesture. A pair one
    // config file short is exactly what a top-up would fetch; start-up
    // must leave it short and never reach the network.
    final store = s.modelStore as DiskModelStore;
    var requests = 0;
    store.dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
      requests++;
      h.reject(DioException(requestOptions: o, message: 'no egress'));
    }));
    final pair = s.registry.byId('opus-mt-en-es')!;
    final small = pair.files.reduce((a, b) => a.bytes <= b.bytes ? a : b);
    for (final f in pair.files) {
      if (identical(f, small)) continue;
      final file = File(store.pathOf(pair, f))..createSync(recursive: true);
      final raf = file.openSync(mode: FileMode.write)..truncateSync(f.bytes);
      raf.closeSync();
    }
    final leftover = File(p.join(dir.path, 'models', 'retired-model', 'm.bin'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(10, 0));
    final audio = File(p.join(dir.path, 'audio', '1.mp3'))
      ..createSync(recursive: true);

    await tidyModels(s);

    expect(leftover.parent.existsSync(), isFalse);
    expect(audio.existsSync(), isTrue);
    expect(requests, 0);
    expect(File(store.pathOf(pair, small)).existsSync(), isFalse);

    // A models path that is a file, not a directory: listing throws.
    final broken = servicesFor(Directory(p.join(dir.path, 'broken')));
    File(p.join(dir.path, 'broken', 'models')).createSync(recursive: true);
    await tidyModels(broken); // completes without throwing
  });

  test('the conditional export resolves to the IO side under the VM', () {
    final fetcher = createFetcher();
    expect(fetcher, isA<IoHttpFetcher>());
    (fetcher as IoHttpFetcher).close();
  });

  test('detachedServices is a usable last resort that touches no channel',
      () {
    // main() falls back to this when createServices() throws (a dead
    // path_provider channel, a full disk). It must not throw itself —
    // a fallback that throws re-brands the launch-logo hang rather than
    // fixing it.
    final s = detachedServices();
    expect(s.modelStore, isA<DiskModelStore>());
    expect(s.executor, isA<InlineTranscribeExecutor>());
    expect(s.foregroundGate, isA<NoopJobForegroundGate>());
  });
}
