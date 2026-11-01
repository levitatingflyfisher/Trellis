import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

/// A release APK without the whisper natives must fail the release recipe.
///
/// The two libraries live in the gitignored
/// `app/android/app/src/main/jniLibs/arm64-v8a/`, and the release recipe
/// builds from a clean `git archive`, which drops gitignored files. Gradle
/// packs whatever is there without complaint, so 1.5.9 shipped with no
/// transcription engine and nothing said so.
void main() {
  const script = '../natives/check-release-apk.sh';
  const baseline = 'lib/arm64-v8a/libwhisper.so';
  const dotprod = 'lib/arm64-v8a/libwhisper_dotprod.so';

  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('apk-natives-'));
  tearDown(() => dir.deleteSync(recursive: true));

  String apkWith(List<String> names) {
    final archive = Archive();
    for (final name in ['classes.dex', ...names]) {
      archive.addFile(ArchiveFile.bytes(name, [1, 2, 3, 4]));
    }
    final path = '${dir.path}/app.apk';
    File(path).writeAsBytesSync(ZipEncoder().encode(archive));
    return path;
  }

  ProcessResult check(String apk) => Process.runSync('bash', [script, apk]);

  test('the guard can see its script', () {
    expect(File(script).existsSync(), isTrue);
  });

  test('passes an APK carrying both libraries', () {
    expect(check(apkWith([baseline, dotprod])).exitCode, 0);
  });

  test('fails an APK carrying neither, naming both', () {
    final result = check(apkWith([]));
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('libwhisper.so'));
    expect(result.stderr, contains('libwhisper_dotprod.so'));
  });

  test('fails without the baseline library', () {
    final result = check(apkWith([dotprod]));
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains(baseline));
  });

  test('fails without the dotprod library', () {
    final result = check(apkWith([baseline]));
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains(dotprod));
  });

  test('another ABI does not stand in for arm64', () {
    final result = check(apkWith([
      'lib/x86_64/libwhisper.so',
      'lib/x86_64/libwhisper_dotprod.so',
    ]));
    expect(result.exitCode, isNot(0));
  });

  test('fails when the APK cannot be read', () {
    expect(check('${dir.path}/absent.apk').exitCode, isNot(0));
  });
}
