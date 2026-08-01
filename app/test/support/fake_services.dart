/// Fakes for the P3 device stack (models, decode, fetch, foreground gate)
/// — every one deterministic and fake-async-friendly: side effects are
/// synchronous file writes or timer beats a `pump` can drive; no sockets,
/// no platform channels, no real isolates.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ml_runtime/ml_runtime.dart';
import 'package:trellis/features/dsp/dsp_encoder.dart';
import 'package:trellis/features/models/model_store.dart';
import 'package:trellis/features/transcribe/audio_fetcher.dart';
import 'package:trellis/features/transcribe/decoder.dart';
import 'package:trellis/features/transcribe/foreground_gate.dart';
import 'package:trellis/features/transcribe/transcribe_executor.dart';
import 'package:trellis/services/device_services.dart';
import 'package:dio/dio.dart' as dio;
import 'package:domovoi/domovoi.dart' show TransferOutcome;

/// In-memory model store. Downloads emit [beats] progress events, one per
/// 100ms fake-time timer tick, then install — so a test can watch progress
/// with `pump(100ms)` and pause mid-flight.
class FakeModelStore implements ModelStore {
  final Set<String> downloadedIds;
  final Map<String, int> partial = {};
  final List<String> downloadsStarted = [];
  final int beats;

  FakeModelStore({Set<String>? downloadedIds, this.beats = 3})
    : downloadedIds = downloadedIds ?? {};

  @override
  Future<bool> isDownloaded(ModelSpec spec) async =>
      downloadedIds.contains(spec.id);

  @override
  Future<int> partialBytes(ModelSpec spec) async => partial[spec.id] ?? 0;

  @override
  Future<void> delete(ModelSpec spec) async {
    downloadedIds.remove(spec.id);
    partial.remove(spec.id);
  }

  @override
  String pathOf(ModelSpec spec, ModelFile file) =>
      '/fake/models/${spec.id}/${Uri.parse(file.url).pathSegments.last}';

  @override
  String voiceDirOf(ModelSpec spec) => '/fake/models/${spec.id}/voice';

  @override
  String dictionaryDirOf(ModelSpec spec) =>
      '/fake/models/${spec.id}/dictionary';

  @override
  ModelDownload download(ModelSpec spec) {
    for (final f in spec.files) {
      if (!f.isPinned) {
        throw StateError('unpinned file in "${spec.id}"');
      }
    }
    downloadsStarted.add(spec.id);
    final controller = StreamController<ModelDownloadProgress>.broadcast();
    var cancelled = false;

    Future<ModelInstallOutcome> run() async {
      final total = spec.sizeBytes;
      for (var i = 1; i <= beats; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (cancelled) {
          partial[spec.id] = total * (i - 1) ~/ beats;
          await controller.close();
          return ModelInstallOutcome.cancelled;
        }
        controller.add(
          ModelDownloadProgress(
            receivedBytes: total * i ~/ beats,
            totalBytes: total,
            etaMs: (beats - i) * 60000,
          ),
        );
      }
      downloadedIds.add(spec.id);
      partial.remove(spec.id);
      await controller.close();
      return ModelInstallOutcome.installed;
    }

    return ModelDownload(
      progress: controller.stream,
      done: run(),
      onCancel: () => cancelled = true,
    );
  }
}

/// Writes the target file synchronously — "the episode arrived" without a
/// socket. Content is irrelevant (the FakeDecoder ignores it).
class FakeAudioFetcher implements AudioFetcher {
  final List<String> fetched = [];

  @override
  Future<TransferOutcome> fetch(
    String url,
    File target, {
    dio.CancelToken? cancelToken,
    void Function(int received, int? total)? onProgress,
  }) async {
    fetched.add(url);
    target.parent.createSync(recursive: true);
    target.writeAsBytesSync(utf8.encode('fake audio for $url'));
    onProgress?.call(1000, 1000);
    return TransferOutcome.completed;
  }
}

/// A fetch driven by hand — `completeDownload()`/cancel-via-token — so a
/// coordinator's mid-flight "downloading" state and cancel path can be
/// observed without a real clock or a real socket.
class ControllableAudioFetcher implements AudioFetcher {
  final List<String> fetched = [];
  Completer<TransferOutcome>? _pending;
  void Function(int received, int? total)? _onProgress;
  File? target;

  @override
  Future<TransferOutcome> fetch(
    String url,
    File target, {
    dio.CancelToken? cancelToken,
    void Function(int received, int? total)? onProgress,
  }) {
    fetched.add(url);
    this.target = target;
    _onProgress = onProgress;
    final pending = _pending = Completer<TransferOutcome>();
    cancelToken?.whenCancel.then((_) {
      if (!pending.isCompleted) pending.complete(TransferOutcome.cancelled);
    });
    return pending.future;
  }

  void emitProgress(int received, int? total) =>
      _onProgress?.call(received, total);

  void completeDownload() {
    final t = target!;
    t.parent.createSync(recursive: true);
    t.writeAsBytesSync(utf8.encode('downloaded'));
    _pending!.complete(TransferOutcome.completed);
  }

  void failDownload(Object error) => _pending!.completeError(error);
}

/// The DSP coordinator's faked ffmpeg boundary (Campaign 6) — success,
/// failure, and garbage-output paths all scriptable per test, so
/// dsp_coordinator_test.dart never shells out to a real ffmpeg binary.
class FakeDspEncoder implements DspEncoder {
  final List<String> processedInputs = [];

  /// duration(path) — every path this fake is asked about that isn't
  /// explicitly registered falls back to [defaultOriginalMs].
  final Map<String, int> durationsByPath = {};
  int defaultOriginalMs;

  /// What [process] writes as the OUTPUT's own duration — read back by
  /// the coordinator's own `durationMs(outputPath)` call, so this is
  /// registered into [durationsByPath] the moment `process` runs.
  int processedMs;

  /// Bytes actually written to the output file — 0 emulates a garbage/
  /// empty encode without the caller needing to intercept file IO.
  int outputBytes;

  /// If set, `process` throws this instead of writing anything — the
  /// "ffmpeg itself failed" path.
  Object? processError;

  FakeDspEncoder({
    this.defaultOriginalMs = 600000,
    this.processedMs = 540000,
    this.outputBytes = 8000000,
  });

  @override
  Future<int> durationMs(String path) async =>
      durationsByPath[path] ?? defaultOriginalMs;

  @override
  Future<void> process({
    required String inputPath,
    required String outputPath,
    required String codec,
    String? bitrate,
  }) async {
    processedInputs.add(inputPath);
    if (processError != null) throw processError!;
    final out = File(outputPath);
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(List.filled(outputBytes, 0));
    durationsByPath[outputPath] = processedMs;
  }
}

/// Ignores the input and synchronously writes [seconds] of silent 16kHz
/// f32le PCM — the deterministic "decoded" artifact.
class FakeDecoder implements Decoder {
  final int seconds;
  final List<String> decoded = [];

  FakeDecoder({this.seconds = 60});

  @override
  Future<void> decodeToPcm16kMono(String inputPath, String outputPath) async {
    decoded.add(inputPath);
    File(outputPath)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(Uint8List(seconds * 16000 * 4));
  }
}

/// Records the notification lifecycle.
class RecordingForegroundGate implements JobForegroundGate {
  final List<String> events = [];

  @override
  Future<void> jobStarted(String title, String text) async {
    events.add('start:$title');
  }

  @override
  Future<void> jobProgress(String title, String text) async {
    events.add('progress:$text');
  }

  @override
  Future<void> jobFinished() async {
    events.add('finished');
  }
}

/// The default two-sentence script the scripted engine replays per window
/// (times are window-relative; the task shifts them into episode time).
List<String> defaultScript() => [
  jsonEncode({
    'text': 'Ola mundo.',
    't0': 0,
    't1': 1500,
    'words': [
      ['Ola', 0, 700],
      ['mundo.', 700, 1500],
    ],
  }),
  jsonEncode({'text': 'Tudo bem?', 't0': 1500, 't1': 2600}),
];

/// A full fake device stack over [dir].
DeviceServices testServices(
  Directory dir, {
  FakeModelStore? modelStore,
  AudioFetcher? audioFetcher,
  FakeDecoder? decoder,
  DspEncoder? dspEncoder,
  RecordingForegroundGate? gate,
  List<String>? script,
  bool localMlAvailable = true,
  DeviceTier tier = DeviceTier.t1,
}) => DeviceServices(
  supportDir: dir,
  modelStore: modelStore ?? FakeModelStore(),
  registry: ModelRegistry.starter(),
  decoder: decoder ?? FakeDecoder(),
  audioFetcher: audioFetcher ?? FakeAudioFetcher(),
  executor: InlineTranscribeExecutor(),
  foregroundGate: gate ?? RecordingForegroundGate(),
  dspEncoder: dspEncoder,
  localMlAvailable: localMlAvailable,
  tier: tier,
  engineFor: (_) => ScriptedEngineSpec(chunkJsons: script ?? defaultScript()),
);
