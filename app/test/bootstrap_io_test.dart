/// The IO side of the conditional bootstrap (bootstrap.dart resolves here
/// on the VM): the pieces main() wires on native platforms, tested without
/// touching a platform channel — the channel-bound wrappers (path_provider)
/// stay thin over these.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:trellis/bootstrap/bootstrap.dart';
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
