import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:trellis/features/models/model_store.dart';

/// A file several models use (Pocket TTS's one Mimi decoder, shared by
/// every language) is downloaded once, kept in `shared/`, and deleted
/// only when the last model that uses it is deleted.
void main() {
  late Directory tmp;
  late HttpServer server;
  var requests = <String>[];
  final own = List<int>.generate(4096, (i) => i % 251);
  final mimi = List<int>.generate(8192, (i) => (i * 3) % 241);

  setUpAll(() => HttpOverrides.global = null);
  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('trellis-shared');
    requests = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      requests.add(req.uri.path);
      final body = req.uri.path.contains('mimi') ? mimi : own;
      req.response.contentLength = body.length;
      req.response.add(body);
      await req.response.close();
    });
  });
  tearDown(() async {
    await server.close(force: true);
    tmp.deleteSync(recursive: true);
  });

  String sha(List<int> b) => crypto.sha256.convert(b).toString();
  String url(String name) => 'http://127.0.0.1:${server.port}/$name';

  ModelSpec voice(String lang) => ModelSpec(
        id: 'pocket-$lang',
        task: ModelTask.tts,
        langs: {lang},
        files: [
          ModelFile(url: url('pocket-$lang-main.onnx'), sha256: sha(own), bytes: own.length),
          ModelFile(
              url: url('pocket-mimi_decoder.onnx'),
              sha256: sha(mimi),
              bytes: mimi.length,
              shared: true),
        ],
        licenses: const ['CC-BY-4.0'],
        minTier: DeviceTier.t1,
      );

  test('the shared file is fetched once for two voices and lives in '
      'shared/', () async {
    final store = DiskModelStore(baseDir: tmp);
    final de = voice('de'), es = voice('es');
    expect(await store.download(de).done, ModelInstallOutcome.installed);
    expect(await store.download(es).done, ModelInstallOutcome.installed);
    expect(requests.where((p) => p.contains('mimi')), hasLength(1));
    final path = store.pathOf(de, de.files[1]);
    expect(path, '${tmp.path}/shared/pocket-mimi_decoder.onnx');
    expect(store.pathOf(es, es.files[1]), path);
    expect(await store.isDownloaded(de), isTrue);
    expect(await store.isDownloaded(es), isTrue);
    expect(await store.missingBytes(es), 0);
  });

  test('a second voice with the shared file already here costs only its '
      'own files', () async {
    final store = DiskModelStore(baseDir: tmp);
    await store.download(voice('de')).done;
    expect(await store.missingBytes(voice('es')), own.length);
    expect(await store.isDownloaded(voice('es')), isFalse,
        reason: 'its own files are not here yet');
  });

  test('deleting one voice keeps the shared file for the other; deleting '
      'the last removes it', () async {
    final store = DiskModelStore(baseDir: tmp);
    final de = voice('de'), es = voice('es');
    await store.download(de).done;
    await store.download(es).done;
    final shared = File(store.pathOf(de, de.files[1]));
    await store.delete(de);
    expect(shared.existsSync(), isTrue);
    expect(await store.isDownloaded(es), isTrue);
    expect(await store.isDownloaded(de), isFalse);
    await store.delete(es);
    expect(shared.existsSync(), isFalse);
  });

  test('pruning keeps a shared file the registry still pins and each '
      'voice’s note that it uses it; drops one nothing pins', () async {
    final store = DiskModelStore(baseDir: tmp);
    final de = voice('de');
    await store.download(de).done;
    final orphan = File('${tmp.path}/shared/old-decoder.onnx')
      ..writeAsBytesSync([1, 2, 3]);
    final freed = await store.pruneUnreferenced(ModelRegistry([de]));
    expect(freed, 3);
    expect(orphan.existsSync(), isFalse);
    expect(await store.isDownloaded(de), isTrue);
  });
}
