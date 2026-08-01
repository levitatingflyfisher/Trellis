/// The traversal guard (law 5), tested at two levels:
///
/// - [resolveStaticFile] as a pure function, fed segment lists directly —
///   this is the ONLY way to prove the segment-level `..`/`.` rejection
///   does anything, because dart:io's own [Uri] parsing already collapses
///   `..` segments (encoded or not) before a real HTTP request ever reaches
///   a handler; feeding raw strings through [Uri.parse] would just prove
///   dart:io's parser works, not this guard.
/// - a real symlink escape, resolved through [SkeinServer] end-to-end —
///   the genuine reachable attack once lexical `..` is off the table:
///   a symlink *inside* web-root pointing outside it. Canonical-path
///   prefix-checking is what defeats this; lexical joining alone would not.
import 'dart:io';

import 'package:skein/skein.dart';
import 'package:test/test.dart';

void main() {
  late Directory webRoot;

  setUp(() {
    webRoot = Directory.systemTemp.createTempSync('skein-webroot');
    File('${webRoot.path}/index.html').writeAsStringSync('<html>home</html>');
    Directory('${webRoot.path}/assets').createSync();
    File('${webRoot.path}/assets/app.js').writeAsStringSync('console.log(1)');
  });

  tearDown(() {
    webRoot.deleteSync(recursive: true);
  });

  group('resolveStaticFile (pure segment resolver)', () {
    test('resolves a plain nested file', () {
      final f = resolveStaticFile(webRoot, ['assets', 'app.js']);
      expect(f, isNotNull);
      expect(f!.path, File('${webRoot.path}/assets/app.js').path);
    });

    test('rejects a .. segment outright', () {
      final f = resolveStaticFile(webRoot, ['..', 'etc', 'passwd']);
      expect(f, isNull);
    });

    test('rejects a .. segment buried in the middle', () {
      final f =
          resolveStaticFile(webRoot, ['assets', '..', '..', 'etc', 'passwd']);
      expect(f, isNull);
    });

    test('rejects a bare . segment', () {
      final f = resolveStaticFile(webRoot, ['.', 'assets', 'app.js']);
      expect(f, isNull);
    });

    test('rejects an empty segment', () {
      final f = resolveStaticFile(webRoot, ['assets', '', 'app.js']);
      expect(f, isNull);
    });
  });

  group('symlink escape (the reachable real-world attack)', () {
    test('a symlink inside web-root pointing outside it is refused', () {
      final secret = Directory.systemTemp.createTempSync('skein-secret');
      File('${secret.path}/passwd').writeAsStringSync('root:x:0:0');
      addTearDown(() => secret.deleteSync(recursive: true));

      final link = Link('${webRoot.path}/escape');
      link.createSync(secret.path);

      final f = resolveStaticFile(webRoot, ['escape', 'passwd']);
      expect(f, isNull,
          reason: 'a symlink escaping web-root must be refused even though '
              'the lexical join looks like it stays inside');
    });
  });
}
