import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:trellis/features/models/model_store.dart';

/// DiskModelStore's dictionary-archive path (Campaign 4 Phase 3) — a
/// StarDict dictionary downloads as one pinned `.tar.gz` (NOT `.tar.bz2`
/// — a separate extraction path from the voice one, since the archive
/// formats differ), then extracts the same way a voice archive does:
/// hash verified before promotion, extracted to a scratch dir, atomically
/// renamed into place, the tarball itself deleted once extraction
/// succeeds.
void main() {
  late Directory tmp;
  late _FixedHost host;
  late List<int> archiveBytes;
  late String archiveSha;

  const layout = DictionaryArchiveLayout(
    topLevelDir: 'Test Dictionary stardict',
    ifoFileName: 'Test Dictionary.ifo',
    idxFileName: 'Test Dictionary.idx',
    dictFileName: 'Test Dictionary.dict.dz',
  );

  List<int> buildArchive({String topLevelDir = 'Test Dictionary stardict'}) {
    final archive = Archive()
      ..add(ArchiveFile(
          '$topLevelDir/${layout.ifoFileName}', 3, 'ifo'.codeUnits))
      ..add(ArchiveFile(
          '$topLevelDir/${layout.idxFileName}', 3, 'idx'.codeUnits))
      ..add(ArchiveFile(
          '$topLevelDir/${layout.dictFileName}', 4, 'dict'.codeUnits));
    final tarBytes = TarEncoder().encodeBytes(archive);
    return GZipEncoder().encodeBytes(tarBytes);
  }

  setUpAll(() {
    HttpOverrides.global = null; // loopback, not egress
  });

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('trellis-dict-archive');
    archiveBytes = buildArchive();
    archiveSha = crypto.sha256.convert(archiveBytes).toString();
    host = await _FixedHost.start(archiveBytes);
  });

  tearDown(() async {
    await host.close();
    tmp.deleteSync(recursive: true);
  });

  ModelSpec spec({String? sha}) => ModelSpec(
        id: 'test-dictionary',
        task: ModelTask.dictionary,
        files: [
          ModelFile(
              url: host.url,
              sha256: sha ?? archiveSha,
              bytes: archiveBytes.length),
        ],
        licenses: const ['CC-BY-SA-3.0'],
        minTier: DeviceTier.t0,
        dictionaryArchiveLayout: layout,
      );

  DiskModelStore store() => DiskModelStore(baseDir: tmp);

  test('a dictionary archive downloads, extracts, and reports installed',
      () async {
    final s = store();
    final m = spec();
    expect(await s.isDownloaded(m), isFalse);

    final outcome = await s.download(m).done;

    expect(outcome, ModelInstallOutcome.installed);
    expect(await s.isDownloaded(m), isTrue);
  });

  test('the extracted files sit flat in dictionaryDirOf — the archive\'s '
      'own top-level wrapper directory is stripped', () async {
    final s = store();
    final m = spec();
    await s.download(m).done;

    final dir = s.dictionaryDirOf(m);
    expect(File('$dir/${layout.ifoFileName}').readAsStringSync(), 'ifo');
    expect(File('$dir/${layout.idxFileName}').readAsStringSync(), 'idx');
    expect(File('$dir/${layout.dictFileName}').readAsStringSync(), 'dict');
    expect(Directory('$dir/${layout.topLevelDir}').existsSync(), isFalse);
  });

  test('the downloaded tarball is deleted once extraction succeeds',
      () async {
    final s = store();
    final m = spec();
    await s.download(m).done;
    expect(File(s.pathOf(m, m.files.single)).existsSync(), isFalse);
  });

  test('a wrong hash fails closed before any extraction is attempted',
      () async {
    final s = store();
    final m = spec(sha: 'deadbeef${'0' * 56}');

    await expectLater(
        s.download(m).done, throwsA(isA<ModelIntegrityException>()));
    expect(await s.isDownloaded(m), isFalse);
    expect(Directory(s.dictionaryDirOf(m)).existsSync(), isFalse);
  });

  test('an archive missing the expected top-level directory fails closed '
      'with a typed extraction error', () async {
    final badArchive = buildArchive(topLevelDir: 'some-other-name');
    final badHost = await _FixedHost.start(badArchive);
    addTearDown(badHost.close);
    final s = store();
    final m = ModelSpec(
      id: 'test-dictionary-bad',
      task: ModelTask.dictionary,
      files: [
        ModelFile(
            url: badHost.url,
            sha256: crypto.sha256.convert(badArchive).toString(),
            bytes: badArchive.length),
      ],
      licenses: const ['CC-BY-SA-3.0'],
      minTier: DeviceTier.t0,
      dictionaryArchiveLayout: layout,
    );

    await expectLater(
        s.download(m).done, throwsA(isA<ModelExtractionException>()));
    expect(Directory(s.dictionaryDirOf(m)).existsSync(), isFalse);
  });
}

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

  String get url => 'http://127.0.0.1:${_server.port}/dictionary.tar.gz';

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
