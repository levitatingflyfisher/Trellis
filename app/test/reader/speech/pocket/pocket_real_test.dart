@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ml_runtime/ml_runtime.dart' show UnigramTokenizer;
import 'package:trellis/features/reader/speech/pocket/pocket_loop.dart';
import 'package:trellis/features/reader/speech/pocket/pocket_text.dart';
import 'package:trellis/features/reader/speech/pocket/pocket_voice.dart';

import '../../../support/ort_marian.dart';

/// The app's own Pocket TTS loop on the real exported graphs, fed the
/// noise Kyutai's loop used, against that loop's trace: the same end
/// frame, the same frame count, latents and end logits within float
/// noise. Skipped unless these are set (model files are never
/// committed):
///
///  * POCKET_MODEL_DIR: the export's folder of language folders;
///  * POCKET_GOLDEN_DIR: `loop_trace_<language>.json` and
///    `tokenizer_<language>.json`;
///  * POCKET_VOICES_DIR: `<language>/<voice>.safetensors`;
///  * ORT_PYTHON: a Python with onnxruntime and numpy.
///
/// The graphs run in ONNX Runtime through test/support/
/// ort_session_server.py; the loop, tokenizer, text preparation and voice
/// reader are the phone's code.
void main() {
  final models = Platform.environment['POCKET_MODEL_DIR'];
  final goldens = Platform.environment['POCKET_GOLDEN_DIR'];
  final voices = Platform.environment['POCKET_VOICES_DIR'];
  final python = Platform.environment['ORT_PYTHON'];
  final skip = models == null ||
          goldens == null ||
          voices == null ||
          python == null
      ? 'set POCKET_MODEL_DIR, POCKET_GOLDEN_DIR, POCKET_VOICES_DIR and '
          'ORT_PYTHON to run'
      : false;
  const langs = {
    'english': PocketLanguage.english,
    'german': PocketLanguage.german,
    'spanish': PocketLanguage.spanish,
    'french': PocketLanguage.french,
    'italian': PocketLanguage.italian,
    'portuguese': PocketLanguage.portuguese,
    'dutch': PocketLanguage.dutch,
  };
  for (final e in langs.entries) {
    test('${e.key}: the loop follows Kyutai’s trace on the real graphs',
        skip: skip, () async {
      final golden = jsonDecode(File('$goldens/loop_trace_${e.key}.json')
          .readAsStringSync()) as Map<String, dynamic>;
      final voice = loadPocketVoice(File(
              '$voices/${e.key}/${golden['voice']}.safetensors')
          .readAsBytesSync());
      final tok = UnigramTokenizer.fromJson(
          File('$goldens/tokenizer_${e.key}.json').readAsStringSync());
      for (final trace
          in (golden['traces'] as List).cast<Map<String, dynamic>>()) {
        final int8 = trace['precision'] == 'int8';
        final sfx = int8 ? '_int8' : '';
        final server = await OrtServer.start(python!, {
          'text': '$models/${e.key}/text_conditioner.onnx',
          'main': '$models/${e.key}/flow_lm_main$sfx.onnx',
          'flow': '$models/${e.key}/flow_lm_flow$sfx.onnx',
          'mimi': '$models/${e.key}/mimi_decoder$sfx.onnx',
        });
        try {
          final z = (_list(trace['noise_z']))
              .map((r) => Float32List.fromList(
                  (r as List).map((v) => (v as num).toDouble()).toList()))
              .toList();
          final gen = PocketGenerator(
            conditioner: OrtRunner(server, 'text'),
            main: OrtRunner(server, 'main'),
            flow: OrtRunner(server, 'flow'),
            mimi: OrtRunner(server, 'mimi'),
            tokenizer: tok,
            language: e.value,
            noise: (c, f) => z[f],
          );
          expect(tok.encode(trace['prepared'] as String),
              _list(trace['token_ids']).cast<int>());
          final audio = await gen.synthesize(trace['text'] as String, voice);
          final frames = _num(trace['frames_emitted']).toInt();
          // fp32 must end on the same frame. int8 may end one frame
          // either side: the end logit climbs steeply (-8.6, -3.4, +20
          // in Dutch), and int8 rounding that differs with the thread
          // count moves the crossing of -4 by a frame.
          final got = audio.length ~/ pocketSamplesPerFrame;
          if (int8) {
            expect((got - frames).abs(), lessThanOrEqualTo(1),
                reason: '${trace['text']} ($got vs $frames frames, int8)');
          } else {
            expect(audio.length, _num(trace['audio_samples']).toInt(),
                reason: '${trace['text']} ($got vs $frames frames, fp32)');
          }
          final want = _list(trace['audio_first8']);
          for (var i = 0; i < want.length; i++) {
            expect(audio[i], closeTo((want[i] as num).toDouble(), 2e-3),
                reason: 'sample $i');
          }
          var sq = 0.0;
          for (final s in audio) {
            sq += s * s;
          }
          final rms = (sq / audio.length);
          final wantRms = _num(trace['audio_rms']).toDouble();
          expect(rms,
              closeTo(wantRms * wantRms, wantRms * wantRms * (int8 ? 0.1 : 0.05)));
          expect(await server.live(), 0, reason: 'every handle released');
          // ignore: avoid_print
          print('${e.key} ${trace['precision']}: ${trace['text']} -> '
              '$got frames (Kyutai $frames), rms ok');
        } finally {
          await server.close();
        }
      }
    });
  }
}

List<dynamic> _list(Object? v) => v is String ? jsonDecode(v) as List : v as List;
num _num(Object? v) => v is String ? num.parse(v) : v as num;
