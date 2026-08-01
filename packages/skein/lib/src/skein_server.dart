/// The daemon itself: bind, route, serve. See the package doc comment
/// (skein.dart) for the one idea; this file is the laws made real.
library;

import 'dart:convert';
import 'dart:io';

import 'fetch_route.dart';
import 'host_guard.dart';
import 'limits.dart';
import 'mime_types.dart';
import 'static_files.dart';
import 'version.dart';

const String fetchPath = '/api/fetch';

class SkeinServer {
  SkeinServer({
    required this.webRoot,
    this.port = 4664,
    int maxFetchBytes = skeinMaxFetchBytes,
    Uri Function(String raw)? urlGuard,
    HostResolver? resolver,
    bool Function(InternetAddress)? isUnsafeAddress,
  }) : _fetcher = SkeinFetcher(
            maxBytes: maxFetchBytes,
            urlGuard: urlGuard,
            resolver: resolver,
            isUnsafeAddress: isUnsafeAddress);

  /// The directory a `flutter build web --base-href /Trellis/` produced.
  final Directory webRoot;

  /// 4664 by default — stove (the household Brain daemon) owns 4663.
  final int port;

  final SkeinFetcher _fetcher;

  HttpServer? _server;

  /// The bound address. Law 1: always loopback — there is no flag to widen
  /// it, so this getter is also the law's proof surface for a test.
  InternetAddress get address => _server!.address;

  int get boundPort => _server!.port;

  /// Binds [InternetAddress.loopbackIPv4] and starts serving. [port] = 0
  /// lets the OS pick an ephemeral port (what every test uses).
  Future<void> start() async {
    final server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server = server;
    server.listen(_handle, onError: (Object _) {});
  }

  Future<void> close() async => _server?.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.method != 'GET') {
        await _writeError(request.response, HttpStatus.methodNotAllowed,
            'Only GET requests are served here.');
        return;
      }

      final path = request.uri.path;
      if (path == '/api/health') {
        await _writeJson(request.response, HttpStatus.ok,
            {'skein': true, 'version': skeinVersion});
        return;
      }
      if (path == fetchPath) {
        await _fetcher.proxy(request);
        return;
      }
      if (path == '/') {
        request.response.statusCode = HttpStatus.movedPermanently;
        request.response.headers.set(HttpHeaders.locationHeader, '/Trellis/');
        await request.response.close();
        return;
      }
      if (path == '/Trellis' || path.startsWith('/Trellis/')) {
        await _serveStatic(request);
        return;
      }
      await _writeError(
          request.response, HttpStatus.notFound, 'Nothing lives there.');
    } catch (_) {
      // A calm sentence beats a stack trace reaching the browser (ADR-0003:
      // errors are sentences) — this is the last-resort net under every
      // route above, not a substitute for their own handling.
      try {
        await _writeError(request.response, HttpStatus.internalServerError,
            'Something went wrong serving that.');
      } catch (_) {
        // The response may already be closed/broken; nothing more to do.
      }
    }
  }

  Future<void> _serveStatic(HttpRequest request) async {
    // Drop the leading 'Trellis' segment; a bare '/Trellis/' or '/Trellis'
    // request leaves an empty remainder, which means "serve index.html".
    final segments = request.uri.pathSegments;
    final remainder = segments.isEmpty ? const <String>[] : segments.sublist(1);
    final effective =
        remainder.where((s) => s.isNotEmpty).toList(growable: false);
    final hadTrailingOnly =
        remainder.isEmpty || remainder.every((s) => s.isEmpty);

    File? file;
    if (hadTrailingOnly) {
      file = resolveStaticFile(webRoot, const ['index.html']);
    } else {
      file = resolveStaticFile(webRoot, effective);
      // SPA fallback: a path with no dot in its last segment is a plausible
      // in-app route (Flutter's router, e.g. /Trellis/study/course/42),
      // never a static asset — serve the shell. A path that DOES look like
      // an asset (has an extension) but is missing or was refused by the
      // traversal guard stays a genuine 404: serving the shell for a
      // missing .js/.png would hide a real broken-build bug.
      if (file == null && !effective.last.contains('.')) {
        file = resolveStaticFile(webRoot, const ['index.html']);
      }
    }

    if (file == null) {
      await _writeError(
          request.response, HttpStatus.notFound, 'Nothing lives there.');
      return;
    }

    final bytes = await file.readAsBytes();
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType =
        ContentType.parse(mimeTypeFor(file.path));
    request.response.add(bytes);
    await request.response.close();
  }

  Future<void> _writeJson(
      HttpResponse response, int status, Map<String, Object?> body) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }

  Future<void> _writeError(
          HttpResponse response, int status, String message) =>
      _writeJson(response, status, {'error': message});
}
