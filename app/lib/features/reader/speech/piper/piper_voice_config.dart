/// What the app reads from a Piper voice's `.onnx.json`: the phoneme id
/// map, the vowel clusters it names, the sample rate and the three
/// inference numbers. For ru_RU denis (medium) these are 22,050 Hz,
/// noise_scale 0.5, length_scale 1.0 and noise_w 0.333.
///
/// The id format was learned from Piper's own source, read and not
/// copied (OHF-Voice/piper1-gpl at 6565650f, GPL):
///  * `src/piper/phoneme_ids.py`, `phonemes_to_ids`, lines 190-204: the
///    BOS id `^`, one pad `_`, then each phoneme's ids each followed by a
///    pad, then the EOS id `$`; a phoneme missing from the map is skipped
///    (`const.py` names `_`, `^` and `$`).
///  * `src/piper/phonemize_espeak.py`, `_merge_known_vowel_clusters`,
///    lines 115-139: the config's vowel clusters (`a`+`ɪ` and so on) are
///    joined into one phoneme before the ids are looked up.
///  * `src/piper/voice.py`, `phoneme_ids_to_audio`, lines 543-554: the
///    model's inputs are `input` (int64 [1,N]), `input_lengths` (int64
///    [1]) and `scales` (float32 [noise_scale, length_scale, noise_w]).
///  * `src/piper/config.py`, `from_dict`, lines 69-96: the sample rate is
///    `audio.sample_rate`, the numbers are under `inference`.
library;

import 'dart:convert';
import 'dart:typed_data';

const _pad = '_', _bos = '^', _eos = r'$';

class PiperVoiceConfig {
  final Map<String, List<int>> phonemeIdMap;
  final List<List<String>> vowelClusters;
  final int sampleRate;
  final double noiseScale;
  final double lengthScale;
  final double noiseW;

  const PiperVoiceConfig({
    required this.phonemeIdMap,
    required this.vowelClusters,
    required this.sampleRate,
    required this.noiseScale,
    required this.lengthScale,
    required this.noiseW,
  });

  /// [json] is the voice's `.onnx.json`. A config without the pad, the
  /// two ends, a sample rate or any of the three numbers is refused:
  /// nothing here guesses a default.
  factory PiperVoiceConfig.parse(String json) {
    try {
      final c = jsonDecode(json) as Map<String, dynamic>;
      final map = <String, List<int>>{
        for (final e in (c['phoneme_id_map'] as Map<String, dynamic>).entries)
          e.key: [for (final id in e.value as List) id as int],
      };
      for (final k in const [_pad, _bos, _eos]) {
        if (map[k]?.isEmpty ?? true) {
          throw FormatException('the phoneme id map has no “$k”');
        }
      }
      final inference = c['inference'] as Map<String, dynamic>;
      double number(String key) => (inference[key] as num).toDouble();
      return PiperVoiceConfig(
        phonemeIdMap: map,
        vowelClusters: [
          for (final v in (c['vowel_clusters'] as List?) ?? const [])
            [for (final p in v as List) p as String],
        ],
        sampleRate: (c['audio'] as Map<String, dynamic>)['sample_rate'] as int,
        noiseScale: number('noise_scale'),
        lengthScale: number('length_scale'),
        noiseW: number('noise_w'),
      );
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('not a Piper voice config: $e');
    }
  }

  /// The model's `scales` input at [rate] (1.0 as the voice speaks; 0.8
  /// takes a quarter longer, so length_scale grows by 1/rate).
  Float32List scales({double rate = 1.0}) =>
      Float32List.fromList([noiseScale, lengthScale / rate, noiseW]);

  /// [phonemes], one symbol each, as the model's input ids.
  List<int> ids(List<String> phonemes) {
    final pad = phonemeIdMap[_pad]!;
    final out = <int>[...phonemeIdMap[_bos]!, ...pad];
    for (final p in _mergeClusters(phonemes)) {
      final id = phonemeIdMap[p];
      if (id == null) continue;
      out
        ..addAll(id)
        ..addAll(pad);
    }
    out.addAll(phonemeIdMap[_eos]!);
    return out;
  }

  /// Each run of symbols that is one of [vowelClusters] as one phoneme,
  /// the longest cluster first.
  List<String> _mergeClusters(List<String> phonemes) {
    if (vowelClusters.isEmpty) return phonemes;
    final longest = vowelClusters.fold(
      0,
      (n, c) => c.length > n ? c.length : n,
    );
    final out = <String>[];
    var i = 0;
    while (i < phonemes.length) {
      List<String>? match;
      for (var n = longest; n > 1 && match == null; n--) {
        if (i + n > phonemes.length) continue;
        for (final c in vowelClusters) {
          if (c.length == n && _startsAt(phonemes, i, c)) {
            match = c;
            break;
          }
        }
      }
      if (match != null) {
        out.add(match.join());
        i += match.length;
      } else {
        out.add(phonemes[i]);
        i++;
      }
    }
    return out;
  }

  static bool _startsAt(List<String> list, int at, List<String> part) {
    for (var k = 0; k < part.length; k++) {
      if (list[at + k] != part[k]) return false;
    }
    return true;
  }
}
