/// `dart run skein --web-root <path/to/build/web> [--port 4664]`
///
/// Serves the Trellis web build and fetches on the app's behalf, so the
/// page and its fetcher share one origin and CORS dissolves. Binds
/// loopback only — open `http://localhost:<port>/Trellis/` in a browser on
/// this machine; nothing else can reach it.
import 'dart:io';

import 'package:skein/skein.dart';

Future<void> main(List<String> args) async {
  String? webRootArg;
  var port = 4664;

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--web-root':
        if (i + 1 >= args.length) {
          _fail('--web-root needs a path.');
        }
        webRootArg = args[++i];
      case '--port':
        if (i + 1 >= args.length) {
          _fail('--port needs a number.');
        }
        final parsed = int.tryParse(args[++i]);
        if (parsed == null) _fail('--port must be a number.');
        port = parsed;
      case '--help':
      case '-h':
        _printUsage();
        return;
      default:
        _fail('Unrecognized argument: ${args[i]}');
    }
  }

  if (webRootArg == null) {
    _fail('--web-root is required.');
  }

  final webRoot = Directory(webRootArg);
  if (!webRoot.existsSync()) {
    _fail("--web-root doesn't exist: ${webRoot.path}");
  }

  final server = SkeinServer(webRoot: webRoot, port: port);
  await server.start();
  stdout.writeln(
      'Skein is serving http://localhost:${server.boundPort}/Trellis/');
  stdout.writeln('(loopback only — nothing outside this machine can reach it)');
}

Never _fail(String message) {
  stderr.writeln(message);
  _printUsage();
  exit(64); // EX_USAGE
}

void _printUsage() {
  stderr.writeln('Usage: dart run skein --web-root <path> [--port 4664]');
}
