import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:trellis/features/models/model_store.dart';

/// DiskModelStore: domovoi's ResumableTransfer + the registry's pinned
/// hashes. The laws under test (proposal-2 §9): true Range resume from the
/// `.part`, sha256 verified in promote BEFORE the atomic rename —
/// fail-closed — cancel keeps the partial, and an unpinned file is not
/// downloadable at all.
void main() {
  late Directory tmp;
  late _RangeHost host;

  /// Deterministic 8KiB body.
  final body = List<int>.generate(8192, (i) => (i * 7) % 251);
  late String bodySha;

  setUpAll(() {
    // The canonical flutter_test_config initializes the widgets binding,
    // whose global HttpClient mock refuses all requests (the anti-egress
    // guard). This suite downloads from a loopback range-server it starts
    // itself — loopback is not egress — so the guard is lifted here.
    HttpOverrides.global = null;
    bodySha = crypto.sha256.convert(body).toString();
  });

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('trellis-models');
    host = await _RangeHost.start(body);
  });

  tearDown(() async {
    await host.close();
    tmp.deleteSync(recursive: true);
  });

  ModelSpec spec({String? sha, int? bytes}) => ModelSpec(
        id: 'test-model',
        task: ModelTask.asr,
        files: [
          ModelFile(
              url: host.url,
              sha256: sha ?? bodySha,
              bytes: bytes ?? body.length),
        ],
        licenses: const ['MIT'],
        minTier: DeviceTier.t1,
      );

  DiskModelStore store() => DiskModelStore(baseDir: tmp);

  test('a fresh download installs the file and reports full progress',
      () async {
    final s = store();
    final m = spec();
    expect(await s.isDownloaded(m), isFalse);

    final received = <int>[];
    final download = s.download(m);
    download.progress.listen((p) => received.add(p.receivedBytes));
    final outcome = await download.done;

    expect(outcome, ModelInstallOutcome.installed);
    expect(await s.isDownloaded(m), isTrue);
    final installed = File(s.pathOf(m, m.files.single));
    expect(installed.readAsBytesSync(), body);
    expect(received.last, body.length);
    expect(
        tmp
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.part')),
        isEmpty,
        reason: 'promotion renames the .part away');
  });

  test('a wrong hash fails closed: no installed file, no poisoned .part',
      () async {
    final s = store();
    final m = spec(sha: 'deadbeef${'0' * 56}');

    final download = s.download(m);
    await expectLater(download.done, throwsA(isA<ModelIntegrityException>()));

    expect(await s.isDownloaded(m), isFalse);
    expect(File(s.pathOf(m, m.files.single)).existsSync(), isFalse);
    expect(
        tmp
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.part')),
        isEmpty,
        reason: 'a full-size .part that failed its hash can never be '
            'resumed into health — it must go');
  });

  test('resume: an existing .part continues with a Range request', () async {
    final s = store();
    final m = spec();

    // First 3000 bytes already on disk from an interrupted attempt.
    final part = File('${s.pathOf(m, m.files.single)}.part')
      ..createSync(recursive: true)
      ..writeAsBytesSync(body.sublist(0, 3000));
    expect(await s.partialBytes(m), 3000);

    final outcome = await s.download(m).done;
    expect(outcome, ModelInstallOutcome.installed);
    expect(host.sawRangeFrom, 3000,
        reason: 'the engine must ask for bytes=3000-, not start over');
    expect(File(s.pathOf(m, m.files.single)).readAsBytesSync(), body);
    expect(part.existsSync(), isFalse);
  });

  test('cancel keeps the .part for a later resume and installs nothing',
      () async {
    host.throttle = true;
    final s = store();
    final m = spec();

    final download = s.download(m);
    // Cancel once the first bytes have landed.
    final sub = download.progress.listen(null);
    sub.onData((p) {
      if (p.receivedBytes > 0) download.cancel();
    });
    final outcome = await download.done;
    await sub.cancel();

    expect(outcome, ModelInstallOutcome.cancelled);
    expect(await s.isDownloaded(m), isFalse);
    expect(File(s.pathOf(m, m.files.single)).existsSync(), isFalse);
    expect(await s.partialBytes(m), greaterThan(0),
        reason: 'cancel is a pause you can walk away from');
  });

  test('an unpinned file is refused before anything touches the wire',
      () async {
    final s = store();
    final unpinned = ModelSpec(
      id: 'unpinned',
      task: ModelTask.asr,
      files: [ModelFile.unverified(url: host.url, bytes: 10)],
      licenses: const ['MIT'],
      minTier: DeviceTier.t1,
    );

    expect(() => s.download(unpinned), throwsStateError);
    expect(host.requests, 0, reason: 'fail-closed means no request at all');
  });

  test('delete removes the installed model', () async {
    final s = store();
    final m = spec();
    await s.download(m).done;
    expect(await s.isDownloaded(m), isTrue);

    await s.delete(m);
    expect(await s.isDownloaded(m), isFalse);
    expect(File(s.pathOf(m, m.files.single)).existsSync(), isFalse);
  });

  test('isDownloaded demands the exact pinned size, not mere existence',
      () async {
    final s = store();
    final m = spec();
    File(s.pathOf(m, m.files.single))
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);
    expect(await s.isDownloaded(m), isFalse);
  });
}

/// A loopback host serving a fixed body with HTTP Range support.
class _RangeHost {
  _RangeHost._(this._server, this._body);

  static Future<_RangeHost> start(List<int> body) async {
    final host = _RangeHost._(
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0), body);
    host._serve();
    return host;
  }

  final HttpServer _server;
  final List<int> _body;

  int requests = 0;
  int? sawRangeFrom;
  bool throttle = false;

  String get url => 'http://127.0.0.1:${_server.port}/model.bin';

  Future<void> close() => _server.close(force: true);

  void _serve() {
    _server.listen((req) async {
      requests++;
      final range = req.headers.value(HttpHeaders.rangeHeader);
      var from = 0;
      if (range != null) {
        final m = RegExp(r'bytes=(\d+)-').firstMatch(range);
        if (m != null) {
          from = int.parse(m.group(1)!);
          sawRangeFrom = from;
        }
      }
      req.response.bufferOutput = false;
      if (from > 0) {
        req.response.statusCode = HttpStatus.partialContent;
        req.response.headers.set(HttpHeaders.contentRangeHeader,
            'bytes $from-${_body.length - 1}/${_body.length}');
      } else {
        req.response.statusCode = HttpStatus.ok;
      }
      req.response.contentLength = _body.length - from;
      try {
        const chunk = 512;
        for (var i = from; i < _body.length; i += chunk) {
          if (throttle) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          req.response.add(_body.sublist(i, math.min(i + chunk, _body.length)));
          await req.response.flush();
        }
        await req.response.close();
      } catch (_) {
        // Client hung up — that is the cancel under test.
      }
    });
  }
}
