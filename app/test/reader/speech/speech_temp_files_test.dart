import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/reader/speech/speech_engine.dart';
import 'package:trellis/features/reader/speech/speech_temp_files.dart';

/// DiskSpeechTempFiles writes real WAV files under a scratch directory;
/// sweepStaleSpeechTempFiles is the app-start cleanup for a session that
/// was killed mid-speech (no chance to run stop()/dispose()). Both touch
/// real disk deliberately — that IS what they're for — under a temp
/// directory this test owns and tears down.
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('speech-temp-test');
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('writes a playable WAV file and reports its path', () async {
    final store = DiskSpeechTempFiles(dir: dir);
    final path = await store.write(
        0, SynthResult(samples: Float32List(100), sampleRate: 16000));
    final file = File(path);
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), 44 + 200); // header + 100 16-bit samples
  });

  test('two runs never collide on the same sentence index', () async {
    final a = DiskSpeechTempFiles(dir: dir);
    final b = DiskSpeechTempFiles(dir: dir);
    final pathA = await a.write(
        0, SynthResult(samples: Float32List(10), sampleRate: 16000));
    final pathB = await b.write(
        0, SynthResult(samples: Float32List(10), sampleRate: 16000));
    expect(pathA, isNot(pathB));
  });

  test('delete removes the file; deleting twice is a quiet no-op', () async {
    final store = DiskSpeechTempFiles(dir: dir);
    final path = await store.write(
        0, SynthResult(samples: Float32List(10), sampleRate: 16000));
    await store.delete(path);
    expect(File(path).existsSync(), isFalse);
    await store.delete(path); // must not throw
  });

  group('sweepStaleSpeechTempFiles', () {
    test('deletes every file left over from a killed session', () async {
      File('${dir.path}/orphan1.wav').writeAsBytesSync([1, 2, 3]);
      File('${dir.path}/orphan2.wav').writeAsBytesSync([4, 5, 6]);
      await sweepStaleSpeechTempFiles(dir);
      expect(dir.listSync(), isEmpty);
    });

    test('a missing directory is not an error', () async {
      final missing = Directory('${dir.path}/does-not-exist');
      await sweepStaleSpeechTempFiles(missing); // must not throw
    });
  });
}
