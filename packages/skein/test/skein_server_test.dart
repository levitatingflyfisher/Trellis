/// SkeinServer end-to-end: real loopback HTTP servers are fine in this
/// pure-Dart package (the flutter_test global-HttpClient-mock landmine does
/// not apply here — app-side tests must still use fake fetchers).
import 'dart:convert';
import 'dart:io';

import 'package:skein/skein.dart';
import 'package:test/test.dart';

void main() {
  late Directory webRoot;
  late SkeinServer server;
  late Uri base;

  setUp(() async {
    webRoot = Directory.systemTemp.createTempSync('skein-webroot');
    File('${webRoot.path}/index.html')
        .writeAsStringSync('<html>home</html>');
    Directory('${webRoot.path}/assets').createSync();
    File('${webRoot.path}/assets/app.js').writeAsStringSync('console.log(1)');
    File('${webRoot.path}/assets/style.css').writeAsStringSync('body{}');
    File('${webRoot.path}/assets/data.json').writeAsStringSync('{}');
    File('${webRoot.path}/assets/icon.png')
        .writeAsBytesSync([0x89, 0x50, 0x4e, 0x47]);
    File('${webRoot.path}/assets/favicon.ico').writeAsBytesSync([0, 1, 2]);
    File('${webRoot.path}/assets/font.otf').writeAsBytesSync([0, 1, 2]);
    File('${webRoot.path}/assets/font.ttf').writeAsBytesSync([0, 1, 2]);
    File('${webRoot.path}/main.dart.wasm').writeAsBytesSync([0, 1, 2]);
    File('${webRoot.path}/main.dart.mjs').writeAsStringSync('export {}');

    server = SkeinServer(webRoot: webRoot, port: 0);
    await server.start();
    base = Uri.parse('http://127.0.0.1:${server.boundPort}');
  });

  tearDown(() async {
    await server.close();
    webRoot.deleteSync(recursive: true);
  });

  test('binds loopback-only, no flag to widen it', () {
    expect(server.address.isLoopback, isTrue);
  });

  test('non-GET is refused with 405 and a JSON sentence', () async {
    final client = HttpClient();
    final req = await client.postUrl(base.resolve('/api/health'));
    final resp = await req.close();
    final body = jsonDecode(await resp.transform(utf8.decoder).join())
        as Map<String, dynamic>;

    expect(resp.statusCode, 405);
    expect(body['error'], isA<String>());
    expect((body['error'] as String).isNotEmpty, isTrue);
    client.close(force: true);
  });

  test('GET /api/health reports the stable probe shape', () async {
    final client = HttpClient();
    final req = await client.getUrl(base.resolve('/api/health'));
    final resp = await req.close();
    final body = jsonDecode(await resp.transform(utf8.decoder).join())
        as Map<String, dynamic>;

    expect(resp.statusCode, 200);
    expect(body['skein'], isTrue);
    expect(body['version'], skeinVersion);
    client.close(force: true);
  });

  test('GET / redirects to /Trellis/', () async {
    final client = HttpClient();
    final req = await client.getUrl(base.resolve('/'));
    req.followRedirects = false;
    final resp = await req.close();
    await resp.drain<void>();

    expect(resp.statusCode, anyOf(301, 302, 303, 307, 308));
    expect(resp.headers.value(HttpHeaders.locationHeader), '/Trellis/');
    client.close(force: true);
  });

  test('serves a real file under /Trellis/ with its MIME type', () async {
    final client = HttpClient();
    final req = await client.getUrl(base.resolve('/Trellis/assets/app.js'));
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();

    expect(resp.statusCode, 200);
    expect(body, 'console.log(1)');
    expect(resp.headers.contentType?.mimeType, 'text/javascript');
    client.close(force: true);
  });

  test('MIME types cover the Flutter web asset set', () async {
    final client = HttpClient();
    final cases = <String, String>{
      '/Trellis/index.html': 'text/html',
      '/Trellis/main.dart.wasm': 'application/wasm',
      '/Trellis/main.dart.mjs': 'text/javascript',
      '/Trellis/assets/style.css': 'text/css',
      '/Trellis/assets/data.json': 'application/json',
      '/Trellis/assets/icon.png': 'image/png',
      '/Trellis/assets/favicon.ico': 'image/x-icon',
      '/Trellis/assets/font.otf': 'font/otf',
      '/Trellis/assets/font.ttf': 'font/ttf',
    };
    for (final entry in cases.entries) {
      final req = await client.getUrl(base.resolve(entry.key));
      final resp = await req.close();
      await resp.drain<void>();
      expect(resp.headers.contentType?.mimeType, entry.value,
          reason: '${entry.key} should be served as ${entry.value}');
    }
    client.close(force: true);
  });

  test('SPA-falls-back an unknown non-file path under /Trellis/ to index.html',
      () async {
    final client = HttpClient();
    final req =
        await client.getUrl(base.resolve('/Trellis/study/course/42'));
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();

    expect(resp.statusCode, 200);
    expect(body, '<html>home</html>');
    expect(resp.headers.contentType?.mimeType, 'text/html');
    client.close(force: true);
  });

  test('a path outside /Trellis/ that is not / or /api/* is a plain 404',
      () async {
    final client = HttpClient();
    final req = await client.getUrl(base.resolve('/nowhere'));
    final resp = await req.close();
    await resp.drain<void>();

    expect(resp.statusCode, 404);
    client.close(force: true);
  });

  test('a symlink inside web-root escaping it is refused end-to-end',
      () async {
    final secret = Directory.systemTemp.createTempSync('skein-secret');
    File('${secret.path}/passwd').writeAsStringSync('root:x:0:0');
    addTearDown(() => secret.deleteSync(recursive: true));
    Link('${webRoot.path}/escape').createSync(secret.path);

    final client = HttpClient();
    final req =
        await client.getUrl(base.resolve('/Trellis/escape/passwd'));
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();

    // Refused as a genuine miss, falling to the SPA shell like any other
    // unservable path — never the secret's contents.
    expect(body, isNot(contains('root:x:0:0')));
    client.close(force: true);
  });
}
