/// Where models live and how they arrive (proposal-2 §9).
///
/// Downloads ride the fleet's ONE engine — domovoi's `resumableDownload` —
/// so resume-from-`.part`, 416/200-restart correctness and cancel-keeps-the-
/// partial are inherited, not re-implemented. What this store adds is the
/// model-trust half: **sha256 verified inside `promote`, before the atomic
/// rename** — fail-closed — and the refusal to download any file the pinned
/// registry has no hash for.
///
/// Layout: `<baseDir>/<modelId>/<filename>` with `.part` growing alongside.
/// The app roots [baseDir] at `appSupport/models/`; tests inject a temp dir.
///
/// A TTS voice (ADR-0006, [VoiceArchiveLayout]) is different: the pinned
/// file is a `.tar.bz2`, and the usable artifact is what's INSIDE it.
/// "Completeness" for one of these becomes the extracted directory's own
/// promotion law — extract to a scratch dir, then atomically rename it
/// into place — mirroring the plain-file law one level up (verify, THEN
/// promote). The tarball itself is deleted once extraction succeeds; there
/// is no reason to keep both the compressed and the extracted copy.
library;

import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:domovoi/domovoi.dart' show TransferOutcome, resumableDownload;
import 'package:ml_runtime/ml_runtime.dart';

import 'download_eta.dart';

/// A downloaded artifact whose bytes do not hash to the registry's pin.
class ModelIntegrityException implements Exception {
  final String message;
  ModelIntegrityException(this.message);

  @override
  String toString() => 'ModelIntegrityException: $message';
}

/// A voice archive that downloaded and hashed correctly but could not be
/// unpacked — a corrupt file, or an upstream release layout that no
/// longer matches the pinned [VoiceArchiveLayout]. Never a silent partial
/// install: on this failure nothing is left at [ModelStore.voiceDirOf].
class ModelExtractionException implements Exception {
  final String message;
  ModelExtractionException(this.message);

  @override
  String toString() => 'ModelExtractionException: $message';
}

/// How a [ModelDownload] ended without error.
enum ModelInstallOutcome { installed, cancelled }

/// One progress beat: cumulative bytes across ALL of the model's files.
class ModelDownloadProgress {
  final int receivedBytes;
  final int totalBytes;

  /// Honest projection from measured throughput; null before evidence.
  final int? etaMs;

  const ModelDownloadProgress(
      {required this.receivedBytes, required this.totalBytes, this.etaMs});
}

/// A running (or finished) model download. Public constructor so fakes can
/// hand the screens the same handle the real store does.
class ModelDownload {
  final Stream<ModelDownloadProgress> progress;

  /// Completes with the outcome once the model is INSTALLED (every file
  /// hashed and renamed) or the run was cancelled. Transfer and integrity
  /// errors surface here.
  final Future<ModelInstallOutcome> done;

  final void Function() _cancel;

  ModelDownload(
      {required this.progress,
      required this.done,
      required void Function() onCancel})
      : _cancel = onCancel;

  /// The pause button: keeps every `.part`, installs nothing.
  void cancel() => _cancel();
}

/// The seam the screens talk to; [DiskModelStore] is the real thing, tests
/// script a fake.
abstract class ModelStore {
  Future<bool> isDownloaded(ModelSpec spec);

  /// Bytes already resting in `.part` files — the "Paused — X of Y" state.
  Future<int> partialBytes(ModelSpec spec);

  Future<void> delete(ModelSpec spec);

  /// Where [file] of [spec] lives once installed (engines load from here).
  /// For an archive [spec] this is the downloaded tarball's OWN path,
  /// which stops existing once extraction succeeds — engines load a
  /// voice's files from [voiceDirOf] instead.
  String pathOf(ModelSpec spec, ModelFile file);

  /// Where a voice's EXTRACTED files live (meaningful only when
  /// `spec.archiveLayout != null`): `<dir>/<archiveLayout.modelFileName>`,
  /// `.../<tokensFileName>`, `.../<dataDirName>/`.
  String voiceDirOf(ModelSpec spec);

  /// Starts (or resumes) the download. Throws [StateError] before anything
  /// touches the wire when any file of [spec] is unpinned.
  ModelDownload download(ModelSpec spec);
}

class DiskModelStore implements ModelStore {
  final Directory baseDir;
  final Dio dio;
  final int Function() _nowMs;

  DiskModelStore({required this.baseDir, Dio? dio, int Function()? nowMs})
      : dio = dio ?? Dio(),
        _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  String _fileName(ModelFile file) => Uri.parse(file.url).pathSegments.last;

  @override
  String pathOf(ModelSpec spec, ModelFile file) =>
      '${baseDir.path}/${spec.id}/${_fileName(file)}';

  @override
  String voiceDirOf(ModelSpec spec) => '${baseDir.path}/${spec.id}/voice';

  @override
  Future<bool> isDownloaded(ModelSpec spec) async {
    if (spec.archiveLayout != null) {
      // Completeness IS the extracted directory's existence — the rename
      // that creates it is atomic, so there is no partially-extracted
      // state to distinguish from "not yet".
      return Directory(voiceDirOf(spec)).existsSync();
    }
    for (final f in spec.files) {
      final file = File(pathOf(spec, f));
      // The exact pinned size, not mere existence — a truncated file is
      // not a model.
      if (!file.existsSync() || file.lengthSync() != f.bytes) return false;
    }
    return true;
  }

  /// Unpacks the downloaded tarball (already hash-verified by the caller)
  /// into [voiceDirOf], atomically, and deletes the tarball. [spec.files]
  /// is always a single archive file for a voice — sherpa-onnx ships one
  /// tarball per voice.
  Future<void> _extract(ModelSpec spec, VoiceArchiveLayout layout) async {
    final tarballFile = File(pathOf(spec, spec.files.single));
    final Archive archive;
    try {
      final compressed = await tarballFile.readAsBytes();
      final tarBytes = BZip2Decoder().decodeBytes(compressed);
      archive = TarDecoder().decodeBytes(tarBytes);
    } catch (e) {
      throw ModelExtractionException(
          'model "${spec.id}": the downloaded archive could not be read '
          '($e) — try re-downloading it');
    }

    final stagingDir = Directory(
        '${baseDir.path}/${spec.id}/.extracting-${_nowMs()}');
    await extractArchiveToDisk(archive, stagingDir.path);

    final unwrapped = Directory('${stagingDir.path}/${layout.topLevelDir}');
    if (!unwrapped.existsSync()) {
      await stagingDir.delete(recursive: true);
      throw ModelExtractionException(
          'model "${spec.id}": the extracted archive did not contain the '
          'expected "${layout.topLevelDir}" directory — the upstream '
          'release layout may have changed');
    }

    final finalDir = Directory(voiceDirOf(spec));
    if (finalDir.existsSync()) await finalDir.delete(recursive: true);
    await finalDir.parent.create(recursive: true);
    // Atomic on the same filesystem — the promotion law, one level up
    // from a plain file's hash-then-rename.
    await unwrapped.rename(finalDir.path);
    if (stagingDir.existsSync()) await stagingDir.delete(recursive: true);
    await tarballFile.delete();
  }

  @override
  Future<int> partialBytes(ModelSpec spec) async {
    var sum = 0;
    for (final f in spec.files) {
      final part = File('${pathOf(spec, f)}.part');
      if (part.existsSync()) sum += part.lengthSync();
    }
    return sum;
  }

  @override
  Future<void> delete(ModelSpec spec) async {
    final dir = Directory('${baseDir.path}/${spec.id}');
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  @override
  ModelDownload download(ModelSpec spec) {
    for (final f in spec.files) {
      if (!f.isPinned) {
        throw StateError(
            'model "${spec.id}" has an unpinned file (${f.url}) — the '
            'registry law forbids downloading it');
      }
    }

    final controller = StreamController<ModelDownloadProgress>.broadcast();
    final cancelToken = CancelToken();
    final eta = DownloadEta();

    Future<ModelInstallOutcome> run() async {
      try {
        var doneBytes = 0;
        for (final f in spec.files) {
          final finalFile = File(pathOf(spec, f));
          if (finalFile.existsSync() && finalFile.lengthSync() == f.bytes) {
            doneBytes += f.bytes; // already installed from an earlier run
            continue;
          }
          final part = File('${finalFile.path}.part');
          await part.parent.create(recursive: true);

          final outcome = await resumableDownload(
            dio: dio,
            url: f.url,
            partFile: part,
            cancelToken: cancelToken,
            onProgress: (received, _) {
              final cumulative = doneBytes + received;
              eta.addSample(atMs: _nowMs(), receivedBytes: cumulative);
              if (!controller.isClosed) {
                controller.add(ModelDownloadProgress(
                    receivedBytes: cumulative,
                    totalBytes: spec.sizeBytes,
                    etaMs: eta.etaMs(
                        remainingBytes: spec.sizeBytes - cumulative)));
              }
            },
            promote: () async {
              // The trust law: hash BEFORE the rename, fail closed. A
              // full-size .part with the wrong hash can never be resumed
              // into health — delete it so the next attempt starts clean.
              final digest =
                  (await crypto.sha256.bind(part.openRead()).first).toString();
              if (digest != f.sha256) {
                await part.delete();
                throw ModelIntegrityException(
                    'model "${spec.id}": ${_fileName(f)} hashed to $digest, '
                    'registry pins ${f.sha256} — refusing to install');
              }
              await part.rename(finalFile.path);
            },
          );
          if (outcome == TransferOutcome.cancelled) {
            return ModelInstallOutcome.cancelled;
          }
          doneBytes += f.bytes;
        }
        final layout = spec.archiveLayout;
        if (layout != null) {
          await _extract(spec, layout);
        }
        if (!controller.isClosed) {
          controller.add(ModelDownloadProgress(
              receivedBytes: spec.sizeBytes,
              totalBytes: spec.sizeBytes,
              etaMs: 0));
        }
        return ModelInstallOutcome.installed;
      } finally {
        unawaited(controller.close());
      }
    }

    return ModelDownload(
        progress: controller.stream,
        done: run(),
        onCancel: () {
          if (!cancelToken.isCancelled) cancelToken.cancel();
        });
  }
}
