import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:trellis/features/models/model_store.dart';

/// DiskModelStore's archive path (ADR-0006): a TTS voice downloads as one
/// pinned .tar.bz2, then gets extracted and atomically renamed into place
/// — "completeness" for an archive spec means the extracted directory
/// exists, mirroring the promotion law a plain file uses (hash verified
/// BEFORE the atomic rename).
void main() {
  late Directory tmp;
  late _FixedHost host;
  late List<int> archiveBytes;
  late String archiveSha;

  const layout = VoiceArchiveLayout(
    topLevelDir: 'vits-piper-en_US-example-medium',
    modelFileName: 'en_US-example-medium.onnx',
    tokensFileName: 'tokens.txt',
    dataDirName: 'espeak-ng-data',
  );

  /// Builds a small synthetic voice bundle with the same shape as the real
  /// sherpa-onnx release tarballs: one top-level dir, the model + tokens
  /// files, and a pronunciation-data directory (one file inside it is
  /// enough — extraction creates parent directories as it goes).
  List<int> buildArchive({String topLevelDir = 'vits-piper-en_US-example-medium'}) {
    final archive = Archive()
      ..add(ArchiveFile(
          '$topLevelDir/${layout.modelFileName}', 6, 'model!'.codeUnits))
      ..add(ArchiveFile(
          '$topLevelDir/${layout.tokensFileName}', 3, 'a 1'.codeUnits))
      ..add(ArchiveFile(
          '$topLevelDir/${layout.dataDirName}/en_dict', 4, 'dict'.codeUnits));
    final tarBytes = TarEncoder().encodeBytes(archive);
    return BZip2Encoder().encodeBytes(tarBytes);
  }

  setUpAll(() {
    HttpOverrides.global = null; // loopback, not egress — see model_store_test.dart
  });

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('trellis-voice-archive');
    archiveBytes = buildArchive();
    archiveSha = crypto.sha256.convert(archiveBytes).toString();
    host = await _FixedHost.start(archiveBytes);
  });

  tearDown(() async {
    await host.close();
    tmp.deleteSync(recursive: true);
  });

  ModelSpec spec({String? sha, VoiceArchiveLayout? withLayout = layout}) =>
      ModelSpec(
        id: 'piper-test-voice',
        task: ModelTask.tts,
        files: [
          ModelFile(
              url: host.url,
              sha256: sha ?? archiveSha,
              bytes: archiveBytes.length),
        ],
        licenses: const ['CC-BY-4.0', 'GPL-3.0'],
        minTier: DeviceTier.t1,
        archiveLayout: withLayout,
      );

  DiskModelStore store() => DiskModelStore(baseDir: tmp);

  test('a voice archive downloads, extracts, and reports installed',
      () async {
    final s = store();
    final m = spec();
    expect(await s.isDownloaded(m), isFalse);

    final outcome = await s.download(m).done;

    expect(outcome, ModelInstallOutcome.installed);
    expect(await s.isDownloaded(m), isTrue);
  });

  test('the extracted voice files sit flat in voiceDirOf — the archive\'s '
      'own top-level wrapper directory is stripped', () async {
    final s = store();
    final m = spec();
    await s.download(m).done;

    final dir = s.voiceDirOf(m);
    expect(File('$dir/${layout.modelFileName}').readAsStringSync(), 'model!');
    expect(File('$dir/${layout.tokensFileName}').readAsStringSync(), 'a 1');
    expect(File('$dir/${layout.dataDirName}/en_dict').existsSync(), isTrue);
    // The wrapper name itself must NOT survive into the final layout.
    expect(Directory('$dir/${layout.topLevelDir}').existsSync(), isFalse);
  });

  test('the downloaded tarball is deleted once extraction succeeds — no '
      'reason to keep both the compressed and the extracted copy',
      () async {
    final s = store();
    final m = spec();
    await s.download(m).done;
    expect(File(s.pathOf(m, m.files.single)).existsSync(), isFalse);
  });

  test('a wrong hash still fails closed BEFORE any extraction is attempted',
      () async {
    final s = store();
    final m = spec(sha: 'deadbeef${'0' * 56}');

    await expectLater(s.download(m).done, throwsA(isA<ModelIntegrityException>()));
    expect(await s.isDownloaded(m), isFalse);
    expect(Directory(s.voiceDirOf(m)).existsSync(), isFalse);
  });

  test('an archive missing the expected top-level directory fails closed '
      'with a typed extraction error, not a silent partial install',
      () async {
    // The upstream release layout changed shape — a real failure mode
    // worth a named exception, not a generic crash.
    final badArchive = buildArchive(topLevelDir: 'some-other-name');
    final badHost = await _FixedHost.start(badArchive);
    addTearDown(badHost.close);
    final s = store();
    final m = ModelSpec(
      id: 'piper-test-voice-bad',
      task: ModelTask.tts,
      files: [
        ModelFile(
            url: badHost.url,
            sha256: crypto.sha256.convert(badArchive).toString(),
            bytes: badArchive.length),
      ],
      licenses: const ['CC-BY-4.0', 'GPL-3.0'],
      minTier: DeviceTier.t1,
      archiveLayout: layout,
    );

    await expectLater(
        s.download(m).done, throwsA(isA<ModelExtractionException>()));
    expect(await s.isDownloaded(m), isFalse);
    expect(Directory(s.voiceDirOf(m)).existsSync(), isFalse);
  });

  test('delete removes both a leftover tarball and the extracted voice dir',
      () async {
    final s = store();
    final m = spec();
    await s.download(m).done;
    expect(await s.isDownloaded(m), isTrue);

    await s.delete(m);
    expect(await s.isDownloaded(m), isFalse);
    expect(Directory(s.voiceDirOf(m)).existsSync(), isFalse);
  });

  test('a non-archive spec is completely unaffected — isDownloaded still '
      'means "exact pinned byte length"', () async {
    final s = store();
    final plain = ModelSpec(
      id: 'plain-model',
      task: ModelTask.asr,
      files: [
        ModelFile(url: host.url, sha256: archiveSha, bytes: archiveBytes.length),
      ],
      licenses: const ['MIT'],
      minTier: DeviceTier.t1,
    );
    await s.download(plain).done;
    expect(await s.isDownloaded(plain), isTrue);
    expect(File(s.pathOf(plain, plain.files.single)).existsSync(), isTrue,
        reason: 'a plain model keeps its downloaded file — no extraction');
  });
}

/// A trivial loopback host serving one fixed body (no Range support
/// needed — the archive path is exercised end to end, resume is already
/// covered by model_store_test.dart's _RangeHost).
class _FixedHost {
  _FixedHost._(this._server, this._body);

  static Future<_FixedHost> start(List<int> body) async {
    final host = _FixedHost._(
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0), body);
    host._serve();
    return host;
  }

  final HttpServer _server;
  final List<int> _body;

  String get url => 'http://127.0.0.1:${_server.port}/voice.tar.bz2';

  Future<void> close() => _server.close(force: true);

  void _serve() {
    _server.listen((req) async {
      req.response.statusCode = HttpStatus.ok;
      req.response.contentLength = _body.length;
      req.response.bufferOutput = false;
      req.response.add(_body);
      await req.response.close();
    });
  }
}
