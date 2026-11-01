import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:trellis/features/models/model_store.dart';

/// DiskModelStore.pruneUnreferenced (1.5.9): files the registry no longer
/// pins go, so a re-pinned decoder or a dropped model stops holding disk.
/// What it must never touch: a download in flight, a paused `.part` the
/// Models screen offers to resume, extracted voice and dictionary
/// directories, and anything outside the models directory.
void main() {
  late Directory support;
  late Directory base;

  // The in-flight test downloads from a loopback server it starts itself;
  // loopback is not egress, so the test binding's network guard is lifted
  // (as model_store_test.dart does).
  setUpAll(() => HttpOverrides.global = null);

  setUp(() {
    support = Directory.systemTemp.createTempSync('trellis-prune');
    base = Directory('${support.path}/models')..createSync();
  });

  tearDown(() => support.deleteSync(recursive: true));

  /// A file of [bytes] length that costs no real disk: only its size is
  /// ever read (isDownloaded and prune go by the pinned length).
  File sized(String path, int bytes) {
    final f = File(path)..parent.createSync(recursive: true);
    final raf = f.openSync(mode: FileMode.write);
    raf.truncateSync(bytes);
    raf.closeSync();
    return f;
  }

  ModelSpec plain(String id, List<(String, int)> files) => ModelSpec(
        id: id,
        task: ModelTask.asr,
        files: [
          for (final (name, bytes) in files)
            ModelFile(
                url: 'https://example.test/$id/$name',
                sha256: 'a' * 64,
                bytes: bytes),
        ],
        licenses: const ['MIT'],
        minTier: DeviceTier.t1,
      );

  test('swapped decoder prunes old file', () async {
    final registry = ModelRegistry.starter();
    final spec = registry.byId('opus-mt-en-es')!;
    final store = DiskModelStore(baseDir: base);
    final decoder = spec.files[1];
    expect(store.pathOf(spec, decoder),
        endsWith('/decoder_model_merged_quantized.onnx'));
    // A 1.5.8 phone: every file of the pair at its pinned size, except the
    // decoder, which is still the 193 MB onnx-community export.
    for (final f in spec.files) {
      if (identical(f, decoder)) continue;
      sized(store.pathOf(spec, f), f.bytes);
    }
    const oldDecoderBytes = 193290224;
    sized(store.pathOf(spec, decoder), oldDecoderBytes);

    expect(await store.pruneUnreferenced(registry), oldDecoderBytes);

    expect(File(store.pathOf(spec, decoder)).existsSync(), isFalse);
    expect(File(store.pathOf(spec, spec.files.first)).existsSync(), isTrue,
        reason: 'the encoder is still pinned and stays');
    expect(await store.missingBytes(spec), decoder.bytes,
        reason: 'only the new decoder is left to fetch');
    expect(decoder.bytes, lessThan(70 * 1000 * 1000));
    expect(await store.pruneUnreferenced(registry), 0,
        reason: 'a second start finds nothing more to do');
  });

  test('prune keeps in-flight .part files', () async {
    final host = await _StallingHost.start(total: 8192, sendFirst: 4096);
    addTearDown(host.close);
    final spec = ModelSpec(
      id: 'in-flight',
      task: ModelTask.asr,
      files: [ModelFile(url: host.url, sha256: 'b' * 64, bytes: 8192)],
      licenses: const ['MIT'],
      minTier: DeviceTier.t1,
    );
    final store = DiskModelStore(baseDir: base);
    final download = store.download(spec);
    final started = Completer<void>();
    final sub = download.progress.listen((p) {
      if (p.receivedBytes > 0 && !started.isCompleted) started.complete();
    });
    await started.future;
    final part = File('${store.pathOf(spec, spec.files.single)}.part');
    expect(part.existsSync(), isTrue);

    // Neither a registry that knows the spec nor one that has since
    // dropped it may pull the file out from under the download.
    expect(await store.pruneUnreferenced(ModelRegistry([spec])), 0);
    expect(await store.pruneUnreferenced(ModelRegistry.starter()), 0);
    expect(part.existsSync(), isTrue);

    download.cancel();
    expect(await download.done, ModelInstallOutcome.cancelled);
    await sub.cancel();
  });

  test('a paused .part of a pinned file is kept for Resume; one larger '
      'than its pin can never finish and goes', () async {
    final a = plain('paused', [('weights.bin', 1000), ('other.bin', 500)]);
    final store = DiskModelStore(baseDir: base);
    final kept = sized('${base.path}/paused/weights.bin.part', 400);
    final tooBig = sized('${base.path}/paused/other.bin.part', 900);

    expect(await store.pruneUnreferenced(ModelRegistry([a])), 900);
    expect(kept.existsSync(), isTrue);
    expect(tooBig.existsSync(), isFalse);
    expect(await store.partialBytes(a), 400);
  });

  test('files a pinned model no longer lists go; installed ones stay',
      () async {
    final a = plain('m', [('keep.bin', 100)]);
    final store = DiskModelStore(baseDir: base);
    final keep = sized('${base.path}/m/keep.bin', 100);
    final stale = sized('${base.path}/m/dropped.onnx', 300);
    final stalePart = sized('${base.path}/m/dropped.onnx.part', 30);

    expect(await store.pruneUnreferenced(ModelRegistry([a])), 330);
    expect(keep.existsSync(), isTrue);
    expect(stale.existsSync(), isFalse);
    expect(stalePart.existsSync(), isFalse);
    expect(await store.isDownloaded(a), isTrue);
  });

  test('a model the registry no longer has is removed whole', () async {
    final store = DiskModelStore(baseDir: base);
    sized('${base.path}/retired-model/model.bin', 700);
    sized('${base.path}/retired-model/model.bin.part', 70);

    expect(await store.pruneUnreferenced(ModelRegistry.starter()), 770);
    expect(Directory('${base.path}/retired-model').existsSync(), isFalse);
  });

  test('pruneUnreferenced deletes a leftover Qwen file', () async {
    // 1.5.8 registered Qwen 2.5 0.5B; a phone that downloaded it (or
    // paused it) still holds up to 547 MB under its old id.
    const qwen = 'qwen2.5-0.5b-instruct-litert';
    const task = 'Qwen2.5-0.5B-Instruct_multi-prefill-seq_q8_ekv1280.task';
    sized('${base.path}/$qwen/$task', 546660344);
    sized('${base.path}/$qwen/$task.part', 1000);
    final store = DiskModelStore(baseDir: base);

    expect(await store.pruneUnreferenced(ModelRegistry.starter()),
        546660344 + 1000);
    expect(Directory('${base.path}/$qwen').existsSync(), isFalse);
  });

  test('overlapping downloads of one spec keep the guard until the last '
      'finishes', () async {
    final host = await _StallingHost.start(total: 8192, sendFirst: 4096);
    addTearDown(host.close);
    final spec = ModelSpec(
      id: 'twice',
      task: ModelTask.asr,
      files: [ModelFile(url: host.url, sha256: 'b' * 64, bytes: 8192)],
      licenses: const ['MIT'],
      minTier: DeviceTier.t1,
    );
    final store = DiskModelStore(baseDir: base);
    Future<(ModelDownload, StreamSubscription<void>)> begin() async {
      final d = store.download(spec);
      final started = Completer<void>();
      final sub = d.progress.listen((p) {
        if (p.receivedBytes > 0 && !started.isCompleted) started.complete();
      });
      await started.future;
      return (d, sub);
    }

    final (first, firstSub) = await begin();
    final (second, secondSub) = await begin();
    first.cancel();
    expect(await first.done, ModelInstallOutcome.cancelled);
    await firstSub.cancel();

    // The second download is still running: a registry that dropped the
    // spec must not take its directory.
    expect(await store.pruneUnreferenced(ModelRegistry.starter()), 0);
    expect(Directory('${base.path}/twice').existsSync(), isTrue);

    second.cancel();
    expect(await second.done, ModelInstallOutcome.cancelled);
    await secondSub.cancel();
    expect(await store.pruneUnreferenced(ModelRegistry.starter()),
        greaterThan(0));
  });

  test('a models directory given with a trailing slash keeps installed '
      'files and still prunes a stale one', () async {
    final registry = ModelRegistry.starter();
    final spec = registry.byId('opus-mt-en-es')!;
    final store =
        DiskModelStore(baseDir: Directory('${support.path}/models/'));
    for (final f in spec.files) {
      sized('${base.path}/${spec.id}/${Uri.parse(f.url).pathSegments.last}',
          f.bytes);
    }
    final stale = sized('${base.path}/${spec.id}/old_extra.onnx', 40);

    expect(await store.pruneUnreferenced(registry), 40);
    expect(stale.existsSync(), isFalse);
    expect(await store.isDownloaded(spec), isTrue);
  });

  test('an installed voice, its shared file, and an extracted dictionary '
      'are not pruned',
      () async {
    final registry = ModelRegistry.starter();
    final dict = registry.byId('wiktionary-en-en-stardict')!;
    final store = DiskModelStore(baseDir: base);
    final ifo = sized(
        '${store.dictionaryDirOf(dict)}/'
        '${dict.dictionaryArchiveLayout!.ifoFileName}',
        50);
    // A Pocket TTS voice: its own files, plus the Mimi decoder every
    // language shares, kept once with a note that this voice uses it.
    final voice = registry.byId('pocket-en')!;
    for (final f in voice.files) {
      sized(store.pathOf(voice, f), f.bytes);
      if (f.shared) {
        sized('${base.path}/${voice.id}/'
            '.uses.${Uri.parse(f.url).pathSegments.last}', 0);
      }
    }

    expect(await store.pruneUnreferenced(registry), 0);
    expect(ifo.existsSync(), isTrue);
    expect(await store.isDownloaded(dict), isTrue);
    expect(await store.isDownloaded(voice), isTrue);
  });

  test('nothing outside the models directory is touched, and links are '
      'not followed', () async {
    final speech = sized('${support.path}/speech-temp/run-1/0.wav', 10);
    final audio = sized('${support.path}/audio/7.mp3', 10);
    final outside = sized('${support.path}/elsewhere/precious.bin', 10);
    Link('${base.path}/linked-dir').createSync('${support.path}/elsewhere');
    sized('${base.path}/silero-vad/silero_vad.onnx', 2327524);
    Link('${base.path}/silero-vad/link.onnx').createSync(outside.path);
    final loose = sized('${base.path}/README', 5);
    final store = DiskModelStore(baseDir: base);

    expect(await store.pruneUnreferenced(ModelRegistry.starter()), 0);
    for (final f in [speech, audio, outside, loose]) {
      expect(f.existsSync(), isTrue, reason: f.path);
    }
  });

  test('a store with no models directory yet frees nothing', () async {
    final store =
        DiskModelStore(baseDir: Directory('${support.path}/not-yet'));
    expect(await store.pruneUnreferenced(ModelRegistry.starter()), 0);
  });
}

/// Sends [sendFirst] of [total] bytes, then holds the connection open
/// until closed: a download that is genuinely in flight.
class _StallingHost {
  _StallingHost._(this._server, this.total, this.sendFirst);

  static Future<_StallingHost> start(
      {required int total, required int sendFirst}) async {
    final host = _StallingHost._(
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        total,
        sendFirst);
    host._serve();
    return host;
  }

  final HttpServer _server;
  final int total;
  final int sendFirst;
  final _release = Completer<void>();

  String get url => 'http://127.0.0.1:${_server.port}/model.bin';

  Future<void> close() async {
    if (!_release.isCompleted) _release.complete();
    await _server.close(force: true);
  }

  void _serve() {
    _server.listen((req) async {
      req.response.bufferOutput = false;
      req.response.contentLength = total;
      try {
        req.response.add(List<int>.filled(sendFirst, 1));
        await req.response.flush();
        await _release.future;
        await req.response.close();
      } catch (_) {
        // The client hung up: the cancel at the end of the test.
      }
    });
  }
}
