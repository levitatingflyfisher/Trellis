import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// A release APK without the whisper natives must fail the release recipe.
///
/// The two libraries live in the gitignored
/// `app/android/app/src/main/jniLibs/arm64-v8a/`, and the release recipe
/// builds from a clean `git archive`, which drops gitignored files. Gradle
/// packs whatever is there without complaint, so 1.5.9 shipped with no
/// transcription engine and nothing said so.
///
/// Since 1.6.0 it must also carry PDFium, and exactly the pinned build:
/// the PDF plugin downloads `libpdfium.so` while the app builds, with no
/// check of its own, so the recipe is where a swapped binary is caught.
void main() {
  const realScript = '../natives/check-release-apk.sh';
  const realPin = '../natives/pdfium-arm64.sha256';
  const pdfium = 'lib/arm64-v8a/libpdfium.so';
  const pdfiumBytes = [80, 68, 70, 105, 117, 109];
  const baseline = 'lib/arm64-v8a/libwhisper.so';
  const dotprod = 'lib/arm64-v8a/libwhisper_dotprod.so';

  late Directory dir;
  late String script;

  // The script reads its pin from the file beside it, so these tests run
  // a copy that sits beside a pin of their own.
  setUp(() {
    dir = Directory.systemTemp.createTempSync('apk-natives-');
    script = '${dir.path}/check-release-apk.sh';
    File(realScript).copySync(script);
    File('${dir.path}/pdfium-arm64.sha256')
        .writeAsStringSync('${sha256.convert(pdfiumBytes)}\n');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  String apkWith(List<String> names, {List<int>? pdfiumIs = pdfiumBytes}) {
    final archive = Archive();
    for (final name in ['classes.dex', ...names]) {
      archive.addFile(ArchiveFile.bytes(name, [1, 2, 3, 4]));
    }
    if (pdfiumIs != null) {
      archive.addFile(ArchiveFile.bytes(pdfium, pdfiumIs));
    }
    final path = '${dir.path}/app.apk';
    File(path).writeAsBytesSync(ZipEncoder().encode(archive));
    return path;
  }

  ProcessResult check(String apk) => Process.runSync('bash', [script, apk]);

  test('the guard can see its script, and the pin is one sha256', () {
    expect(File(realScript).existsSync(), isTrue);
    expect(File(realPin).readAsStringSync().trim(),
        matches(RegExp(r'^[0-9a-f]{64}$')));
  });

  test('fails without PDFium', () {
    final result = check(apkWith([baseline, dotprod], pdfiumIs: null));
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains(pdfium));
  });

  test('fails when PDFium is not the pinned build, giving both hashes',
      () {
    final result = check(apkWith([baseline, dotprod], pdfiumIs: [9, 9, 9]));
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('${sha256.convert(pdfiumBytes)}'));
    expect(result.stderr, contains('${sha256.convert([9, 9, 9])}'));
  });

  test('fails closed when the pin itself is missing', () {
    File('${dir.path}/pdfium-arm64.sha256').deleteSync();
    final result = check(apkWith([baseline, dotprod]));
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('pdfium-arm64.sha256'));
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
