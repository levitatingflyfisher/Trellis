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
/// A StarDict dictionary ([DictionaryArchiveLayout]) is different: the
/// pinned file is a `.tar.gz`, and the usable artifact is what's INSIDE
/// it. "Completeness" for one becomes the extracted directory's own
/// promotion law: extract to a scratch dir, then atomically rename it
/// into place, the plain-file law one level up (verify, THEN promote).
/// The tarball is deleted once extraction succeeds.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
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

/// A dictionary archive that downloaded and hashed correctly but could
/// not be unpacked: a corrupt file, or an upstream release layout that no
/// longer matches the pinned [DictionaryArchiveLayout]. Never a silent
/// partial install: on this failure nothing is left at
/// [ModelStore.dictionaryDirOf].
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

  /// Bytes a download of [spec] would still fetch: zero once installed.
  /// Files already complete are skipped by [download], so a spec that
  /// gained a small file (1.5.5's translation configs) costs only that.
  Future<int> missingBytes(ModelSpec spec);

  Future<void> delete(ModelSpec spec);

  /// Where [file] of [spec] lives once installed (engines load from here).
  /// For a dictionary [spec] this is the downloaded tarball's OWN path,
  /// which stops existing once extraction succeeds; the dictionary is
  /// read from [dictionaryDirOf] instead.
  String pathOf(ModelSpec spec, ModelFile file);

  /// Where a dictionary's EXTRACTED files live (meaningful only when
  /// `spec.dictionaryArchiveLayout != null`, Campaign 4 Phase 3):
  /// `<dir>/<layout.ifoFileName>`, `.../<idxFileName>`,
  /// `.../<dictFileName>`.
  String dictionaryDirOf(ModelSpec spec);

  /// Starts (or resumes) the download. Throws [StateError] before anything
  /// touches the wire when any file of [spec] is unpinned.
  ModelDownload download(ModelSpec spec);

  /// Deletes model files [registry] no longer pins and returns the bytes
  /// freed: a model it dropped, a file its spec dropped, a file whose pin
  /// changed size (a re-pinned decoder keeps its file name), and a `.part`
  /// that can never finish. Size-based stale detection covers plain files
  /// only: a re-pinned archive spec (dictionary, voice) keeps its extracted
  /// directory and is not detected. Never touches a model whose download is in
  /// flight, a paused `.part` that can still resume, extracted voice or
  /// dictionary directories, or anything outside the models directory.
  Future<int> pruneUnreferenced(ModelRegistry registry);
}

class DiskModelStore implements ModelStore {
  final Directory baseDir;
  final Dio dio;
  final int Function() _nowMs;

  /// Running downloads per spec id in this store; [pruneUnreferenced]
  /// leaves their directories alone whatever the registry says. A count,
  /// not a set: two overlapping downloads of one spec keep the guard
  /// until the last one ends.
  final Map<String, int> _inFlight = {};

  DiskModelStore({required this.baseDir, Dio? dio, int Function()? nowMs})
      : dio = dio ?? Dio(),
        _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  String _fileName(ModelFile file) => Uri.parse(file.url).pathSegments.last;

  @override
  String pathOf(ModelSpec spec, ModelFile file) => file.shared
      ? '${baseDir.path}/$_sharedDir/${_fileName(file)}'
      : '${baseDir.path}/${spec.id}/${_fileName(file)}';

  /// Where a file several models use is kept, once.
  static const _sharedDir = 'shared';

  /// The note in a model's own folder that it uses a shared file: a
  /// shared file goes when the last note naming it does.
  String _useNote(ModelSpec spec, ModelFile file) =>
      '${baseDir.path}/${spec.id}/.uses.${_fileName(file)}';

  Future<void> _noteUse(ModelSpec spec, ModelFile file) async {
    final note = File(_useNote(spec, file));
    await note.parent.create(recursive: true);
    if (!note.existsSync()) await note.writeAsString('');
  }

  @override
  String dictionaryDirOf(ModelSpec spec) =>
      '${baseDir.path}/${spec.id}/dictionary';

  @override
  Future<bool> isDownloaded(ModelSpec spec) async {
    if (spec.dictionaryArchiveLayout != null) {
      return Directory(dictionaryDirOf(spec)).existsSync();
    }
    for (final f in spec.files) {
      final file = File(pathOf(spec, f));
      // The exact pinned size, not mere existence — a truncated file is
      // not a model.
      if (!file.existsSync() || file.lengthSync() != f.bytes) return false;
      if (f.shared && !File(_useNote(spec, f)).existsSync()) return false;
    }
    return true;
  }

  /// Unpacks the downloaded `.tar.gz` (already hash-verified by the
  /// caller) into [dictionaryDirOf], atomically, and deletes the tarball
  /// (Campaign 4 Phase 3): stage, check the wrapper dir, rename, delete.
  Future<void> _extractDictionary(
      ModelSpec spec, DictionaryArchiveLayout layout) async {
    final tarballFile = File(pathOf(spec, spec.files.single));
    final Archive archive;
    try {
      final compressed = await tarballFile.readAsBytes();
      final tarBytes = GZipDecoder().decodeBytes(compressed);
      archive = TarDecoder().decodeBytes(tarBytes);
    } catch (e) {
      debugPrint('model "${spec.id}": archive unreadable: $e');
      throw ModelExtractionException(
          "The downloaded file couldn’t be unpacked. Try downloading it "
          'again.');
    }

    final stagingDir = Directory(
        '${baseDir.path}/${spec.id}/.extracting-${_nowMs()}');
    await extractArchiveToDisk(archive, stagingDir.path);

    final unwrapped = Directory('${stagingDir.path}/${layout.topLevelDir}');
    if (!unwrapped.existsSync()) {
      await stagingDir.delete(recursive: true);
      throw ModelExtractionException(
          'model “${spec.id}”: the extracted archive did not contain the '
          'expected “${layout.topLevelDir}” directory; the upstream '
          'release layout may have changed');
    }

    final finalDir = Directory(dictionaryDirOf(spec));
    if (finalDir.existsSync()) await finalDir.delete(recursive: true);
    await finalDir.parent.create(recursive: true);
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
  Future<int> missingBytes(ModelSpec spec) async {
    if (await isDownloaded(spec)) return 0;
    if (spec.dictionaryArchiveLayout != null) {
      return spec.sizeBytes - await partialBytes(spec);
    }
    var sum = 0;
    for (final f in spec.files) {
      final file = File(pathOf(spec, f));
      if (file.existsSync() && file.lengthSync() == f.bytes) continue;
      final part = File('${file.path}.part');
      sum += f.bytes - (part.existsSync() ? part.lengthSync() : 0);
    }
    return sum;
  }

  @override
  Future<void> delete(ModelSpec spec) async {
    final dir = Directory('${baseDir.path}/${spec.id}');
    if (dir.existsSync()) await dir.delete(recursive: true);
    // A shared file goes with the last model that noted it uses it.
    for (final f in spec.files.where((f) => f.shared)) {
      final note = '.uses.${_fileName(f)}';
      final stillUsed = baseDir.existsSync() &&
          baseDir.listSync(followLinks: false).whereType<Directory>().any(
              (d) => File('${d.path}/$note').existsSync());
      if (stillUsed) continue;
      final file = File(pathOf(spec, f));
      if (file.existsSync()) await file.delete();
    }
  }

  @override
  ModelDownload download(ModelSpec spec) {
    for (final f in spec.files) {
      if (!f.isPinned) {
        throw StateError(
            'model “${spec.id}” has an unpinned file (${f.url}); the '
            'registry law forbids downloading it');
      }
    }

    final controller = StreamController<ModelDownloadProgress>.broadcast();
    final cancelToken = CancelToken();
    final eta = DownloadEta();
    _inFlight.update(spec.id, (n) => n + 1, ifAbsent: () => 1);

    Future<ModelInstallOutcome> run() async {
      try {
        var doneBytes = 0;
        for (final f in spec.files) {
          final finalFile = File(pathOf(spec, f));
          if (finalFile.existsSync() && finalFile.lengthSync() == f.bytes) {
            doneBytes += f.bytes; // already installed from an earlier run
            if (f.shared) await _noteUse(spec, f);
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
                // The engine's If-Range sidecar named the bytes just
                // thrown away.
                final validator = File('${part.path}.validator');
                if (validator.existsSync()) await validator.delete();
                throw ModelIntegrityException(
                    'model “${spec.id}”: ${_fileName(f)} hashed to $digest, '
                    'registry pins ${f.sha256}, so it was not installed');
              }
              await part.rename(finalFile.path);
            },
          );
          if (outcome == TransferOutcome.cancelled) {
            return ModelInstallOutcome.cancelled;
          }
          if (f.shared) await _noteUse(spec, f);
          doneBytes += f.bytes;
        }
        final dictLayout = spec.dictionaryArchiveLayout;
        if (dictLayout != null) {
          await _extractDictionary(spec, dictLayout);
        }
        if (!controller.isClosed) {
          controller.add(ModelDownloadProgress(
              receivedBytes: spec.sizeBytes,
              totalBytes: spec.sizeBytes,
              etaMs: 0));
        }
        return ModelInstallOutcome.installed;
      } finally {
        final left = _inFlight[spec.id]! - 1;
        if (left == 0) {
          _inFlight.remove(spec.id);
        } else {
          _inFlight[spec.id] = left;
        }
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

  @override
  Future<int> pruneUnreferenced(ModelRegistry registry) async {
    if (!baseDir.existsSync()) return 0;
    final byId = {for (final s in registry.specs) s.id: s};
    var freed = 0;
    // Links are never followed or removed: only what the store itself
    // wrote under baseDir is a candidate.
    final sharedPins = {
      for (final s in registry.specs)
        for (final f in s.files)
          if (f.shared) _fileName(f): f.bytes,
    };
    for (final entry in baseDir.listSync(followLinks: false)) {
      if (entry is! Directory) continue; // loose files here aren't ours
      final id = _baseName(entry.path);
      if (id == _sharedDir) {
        if (_inFlight.isNotEmpty) continue; // a download may be filling it
        for (final child in entry.listSync(followLinks: false)) {
          if (child is! File) continue;
          final name = _baseName(child.path);
          final base = name.endsWith('.part')
              ? name.substring(0, name.length - '.part'.length)
              : name.endsWith('.part.validator')
                  ? name.substring(0, name.length - '.part.validator'.length)
                  : name;
          final pin = sharedPins[base];
          final keep = pin != null &&
              (name != base || child.lengthSync() == pin);
          if (keep) continue;
          freed += child.lengthSync();
          await child.delete();
        }
        continue;
      }
      if (_inFlight.containsKey(id)) continue;
      final spec = byId[id];
      if (spec == null) {
        // A model this registry no longer has (Qwen, 1.5.9): nothing can
        // download into it again, so it goes whole.
        freed += _bytesUnder(entry);
        await entry.delete(recursive: true);
        continue;
      }
      // Keyed by file name, not full path: listSync's spelling of a path
      // (a trailing slash on baseDir, say) need not match pathOf's, and a
      // mismatch would read every installed file as unlisted.
      final pinned = {
        for (final f in spec.files)
          if (!f.shared) _fileName(f): f.bytes,
      };
      final notes = {
        for (final f in spec.files)
          if (f.shared) '.uses.${_fileName(f)}',
      };
      for (final child in entry.listSync(followLinks: false)) {
        // Subdirectories are extracted voices/dictionaries or a staging
        // dir; only plain files are judged. A validator may already have
        // gone with its `.part`.
        if (child is! File || !child.existsSync()) continue;
        final path = _baseName(child.path);
        if (notes.contains(path)) continue;
        final String? stale;
        if (path.endsWith('.part.validator')) {
          final part = path.substring(0, path.length - '.validator'.length);
          final base = part.substring(0, part.length - '.part'.length);
          stale = pinned.containsKey(base) ? null : path;
        } else if (path.endsWith('.part')) {
          final base = path.substring(0, path.length - '.part'.length);
          final pin = pinned[base];
          // A partial longer than its file can't resume into a match.
          stale = pin == null || child.lengthSync() > pin ? path : null;
        } else {
          final pin = pinned[path];
          // Only promote() puts a file here, after its hash matched, so a
          // length off the pin is an earlier pin's file.
          stale = pin == null || child.lengthSync() != pin ? path : null;
        }
        if (stale == null || _inFlight.containsKey(id)) continue;
        freed += child.lengthSync();
        await child.delete();
        if (stale.endsWith('.part')) {
          final validator = File('${child.path}.validator');
          if (validator.existsSync()) {
            freed += validator.lengthSync();
            await validator.delete();
          }
        }
      }
    }
    return freed;
  }

  static String _baseName(String path) =>
      path.split(Platform.pathSeparator).lastWhere((s) => s.isNotEmpty,
          orElse: () => path);

  static int _bytesUnder(Directory dir) {
    var sum = 0;
    for (final e in dir.listSync(recursive: true, followLinks: false)) {
      if (e is File) sum += e.lengthSync();
    }
    return sum;
  }
}
