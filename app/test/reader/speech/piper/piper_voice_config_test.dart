import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/reader/speech/piper/piper_voice_config.dart';

/// The parts of a Piper voice config the app reads, written by hand. The
/// ids for p, r, ʲ, ɪ, ˈ, v, e and t are the denis voice's own.
String configJson({
  Map<String, Object?>? inference,
  List<List<String>>? clusters,
  Map<String, List<int>>? extra,
}) => jsonEncode({
  'audio': {'sample_rate': 22050, 'quality': 'medium'},
  'inference':
      inference ?? {'noise_scale': 0.5, 'length_scale': 1.0, 'noise_w': 0.333},
  'vowel_clusters': ?clusters,
  'phoneme_id_map': {
    '_': [0],
    '^': [1],
    r'$': [2],
    ' ': [3],
    ',': [8],
    'a': [14],
    'b': [15],
    'e': [18],
    'p': [28],
    'r': [30],
    't': [32],
    'v': [34],
    'ɪ': [74],
    'ʲ': [119],
    'ˈ': [120],
    ...?extra,
  },
});

void main() {
  test('the numbers the denis voice is read with come from its config', () {
    final c = PiperVoiceConfig.parse(configJson());
    expect(c.sampleRate, 22050);
    expect(c.noiseScale, 0.5);
    expect(c.lengthScale, 1.0);
    expect(c.noiseW, 0.333);
  });

  test('a config with no sample rate or no inference numbers is refused', () {
    expect(
      () => PiperVoiceConfig.parse('{"phoneme_id_map": {}}'),
      throwsFormatException,
    );
    expect(
      () => PiperVoiceConfig.parse(configJson(inference: {'noise_scale': 0.5})),
      throwsFormatException,
    );
  });

  group('phoneme ids', () {
    final c = PiperVoiceConfig.parse(configJson());

    test('^ and a pad, each phoneme then a pad, then \$', () {
      expect(c.ids(['a']), [1, 0, 14, 0, 2]);
      expect(c.ids(['a', ' ', 'b']), [1, 0, 14, 0, 3, 0, 15, 0, 2]);
    });

    test('nothing to say is still ^ _ \$', () {
      expect(c.ids(const []), [1, 0, 2]);
    });

    test('привет, as the voice takes it', () {
      expect(c.ids('prʲɪˈvʲet'.split('')), [
        1,
        0,
        28,
        0,
        30,
        0,
        119,
        0,
        74,
        0,
        120,
        0,
        34,
        0,
        119,
        0,
        18,
        0,
        32,
        0,
        2,
      ]);
    });

    test('a phoneme the map does not have is left out', () {
      expect(c.ids(['a', 'ж', 'b']), [1, 0, 14, 0, 15, 0, 2]);
    });

    test('a phoneme with several ids gives them all, then one pad', () {
      final multi = PiperVoiceConfig.parse(
        configJson(
          extra: {
            'ʦ': [32, 31],
          },
        ),
      );
      expect(multi.ids(['ʦ']), [1, 0, 32, 31, 0, 2]);
    });

    test('vowel clusters the config names are one phoneme each', () {
      final withClusters = PiperVoiceConfig.parse(
        configJson(
          clusters: [
            ['a', 'ɪ'],
          ],
          extra: {
            'aɪ': [161],
          },
        ),
      );
      expect(withClusters.ids(['b', 'a', 'ɪ', 'a']), [
        1,
        0,
        15,
        0,
        161,
        0,
        14,
        0,
        2,
      ]);
      // Without the config's word, the two stay two.
      expect(c.ids(['a', 'ɪ']), [1, 0, 14, 0, 74, 0, 2]);
    });
  });
}
