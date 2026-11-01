import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/reader/speech/piper/piper_engine.dart';
import 'package:trellis/features/reader/speech/piper/piper_front_end.dart';

/// The Russian front end from its files: the voice config and the stress
/// table, read once; then each sentence marked, into phonemes, into ids.
void main() {
  late Directory dir;
  late String configPath;
  late String stressPath;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('trellis-piper');
    // Ids for p, r, ʲ, ɪ, ˈ, v, e, t, ',', ' ' are the denis voice's own.
    configPath = '${dir.path}/ru_RU-denis-medium.onnx.json';
    File(configPath).writeAsStringSync(
      jsonEncode({
        'audio': {'sample_rate': 22050},
        'inference': {
          'noise_scale': 0.5,
          'length_scale': 1.0,
          'noise_w': 0.333,
        },
        'phoneme_id_map': {
          '_': [0],
          '^': [1],
          r'$': [2],
          ' ': [3],
          ',': [8],
          'e': [18],
          'p': [28],
          'r': [30],
          't': [32],
          'v': [34],
          'ɪ': [74],
          'ʲ': [119],
          'ˈ': [120],
        },
      }),
    );
    stressPath = '${dir.path}/ru-stress.tsv';
    File(stressPath).writeAsStringSync('привет\t1\n');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('a sentence is marked from the table, then said as the voice’s '
      'phonemes', () async {
    final fe = await loadPiperFrontEnd(
      configPath: configPath,
      stressPath: stressPath,
    );
    expect(fe.config.sampleRate, 22050);
    expect(fe.phonemes('Привет'), 'prʲɪˈvʲet'.split(''));
    expect(fe.config.ids(fe.phonemes('Привет')), [
      1, 0, 28, 0, 30, 0, 119, 0, 74, 0, 120, 0, //
      34, 0, 119, 0, 18, 0, 32, 0, 2,
    ]);
  });

  test('without a table, a word of two vowels has no stress', () async {
    final fe = await loadPiperFrontEnd(configPath: configPath);
    expect(fe.phonemes('Привет'), isNot(contains('ˈ')));
    expect(fe.phonemes('Приве́т'), 'prʲɪˈvʲet'.split(''));
  });

  test('a missing file is a calm, typed error', () async {
    File(stressPath).deleteSync();
    await expectLater(
      loadPiperFrontEnd(configPath: configPath, stressPath: stressPath),
      throwsA(isA<PiperMissingFilesException>()),
    );
    File(configPath).deleteSync();
    await expectLater(
      loadPiperFrontEnd(configPath: configPath),
      throwsA(isA<PiperMissingFilesException>()),
    );
  });
}
