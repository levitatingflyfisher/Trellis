import 'dart:convert';

import 'package:loom_core/loom_core.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:test/test.dart';
import 'package:transcribe_core/transcribe_core.dart';

/// The result codec: a [TranscriptionResult] crosses the isolate boundary as
/// its canonical JSON and MUST come back whole — the app writes spine rows
/// from the decoded side.
void main() {
  TranscriptionResult sample() => TranscriptionResult(
        lang: 'pt',
        layerKind: LayerKind.transcript,
        segments: const [
          Segment(idx: 0, kind: SegmentKind.prose, text: 'Olá mundo.'),
          Segment(idx: 1, kind: SegmentKind.prose, text: 'Tudo bem?'),
        ],
        alignments: const [
          Alignment(segmentIdx: 0, tStartMs: 0, tEndMs: 1500),
          Alignment(segmentIdx: 1, tStartMs: 1500, tEndMs: 2600),
        ],
        layers: const [
          Layer(
              segmentIdx: 0,
              lang: 'pt',
              kind: LayerKind.transcript,
              text: 'Olá mundo.'),
          Layer(
              segmentIdx: 1,
              lang: 'pt',
              kind: LayerKind.transcript,
              text: 'Tudo bem?'),
        ],
        mergedChunks: [
          TranscriptChunk(text: 'Olá mundo.', tStartMs: 0, tEndMs: 1500, words: [
            WordTiming(word: 'Olá', tStartMs: 0, tEndMs: 700),
            WordTiming(word: 'mundo.', tStartMs: 700, tEndMs: 1500),
          ]),
          TranscriptChunk(text: 'Tudo bem?', tStartMs: 1500, tEndMs: 2600),
        ],
      );

  test('fromJson(toJson) is the identity, canonically', () {
    final original = sample();
    final decoded = TranscriptionResult.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>);

    expect(jsonEncode(decoded.toJson()), jsonEncode(original.toJson()));
    expect(decoded.lang, 'pt');
    expect(decoded.layerKind, LayerKind.transcript);
    expect(decoded.segments, hasLength(2));
    expect(decoded.segments[1].text, 'Tudo bem?');
    expect(decoded.alignments[0].tEndMs, 1500);
    expect(decoded.layers[0].kind, LayerKind.transcript);
    expect(decoded.mergedChunks[0].words, hasLength(2));
    expect(decoded.mergedChunks[1].words, isNull);
  });

  test('an mt (translate) result keeps its layer kind', () {
    final original = TranscriptionResult(
      lang: 'en',
      layerKind: LayerKind.mt,
      segments: const [Segment(idx: 0, kind: SegmentKind.prose, text: 'Hi.')],
      alignments: const [Alignment(segmentIdx: 0, tStartMs: 0, tEndMs: 400)],
      layers: const [
        Layer(segmentIdx: 0, lang: 'en', kind: LayerKind.mt, text: 'Hi.')
      ],
      mergedChunks: [TranscriptChunk(text: 'Hi.', tStartMs: 0, tEndMs: 400)],
    );
    final decoded = TranscriptionResult.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>);
    expect(decoded.layerKind, LayerKind.mt);
    expect(decoded.layers.single.kind, LayerKind.mt);
  });
}
