/// Transcription as a checkpointed `jobs_core` task (proposal-2 §9).
///
/// One UNIT = one window (30s, 5s overlap by default) read off the seekable
/// [PcmSource], VAD-gated, transcribed through `ml_runtime`'s `Transcriber`
/// seam. The checkpoint after every unit is `{nextWindowStartMs, chunks so
/// far}` — everything a fresh instance needs, so a process kill anywhere
/// resumes byte-identical (proved by the kill-sweep property test).
///
/// The final assembly, [buildResult], is pure: `mergeOverlap` resolves the
/// window seams, [segmentize] cuts sentence-ish segments, and the output is
/// spine-ready `loom_core` rows — `Segment`s, `Alignment`s and one text
/// `Layer` per segment (`transcript` in the source language, or `mt` in
/// `'en'` when the task is Whisper's translate).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:jobs_core/jobs_core.dart';
import 'package:loom_core/loom_core.dart';
import 'package:ml_runtime/ml_runtime.dart';

import 'pcm_source.dart';
import 'segmentize.dart';
import 'window_plan.dart';

/// Best-effort language detection over the merged transcript. Returning
/// null means "could not tell" — the result then carries `'und'`.
typedef LangDetector = String? Function(List<TranscriptChunk> mergedChunks);

/// Everything the spine needs from one transcribed episode.
class TranscriptionResult {
  /// Language of the produced layer rows: the source language for a
  /// transcribe run, always `'en'` for a translate run.
  final String lang;

  /// `LayerKind.transcript` for transcribe, `LayerKind.mt` for translate.
  final LayerKind layerKind;

  final List<Segment> segments;
  final List<Alignment> alignments;
  final List<Layer> layers;

  /// The merged, tiled transcript chunks — word timings (best-effort by
  /// contract, ADR-0002) live here for callers that want them.
  final List<TranscriptChunk> mergedChunks;

  TranscriptionResult({
    required this.lang,
    required this.layerKind,
    required List<Segment> segments,
    required List<Alignment> alignments,
    required List<Layer> layers,
    required List<TranscriptChunk> mergedChunks,
  })  : segments = List.unmodifiable(segments),
        alignments = List.unmodifiable(alignments),
        layers = List.unmodifiable(layers),
        mergedChunks = List.unmodifiable(mergedChunks);

  /// The inverse of [toJson] — how a result crosses an isolate boundary and
  /// comes back whole (the app writes spine rows from the decoded side).
  factory TranscriptionResult.fromJson(Map<String, dynamic> m) {
    final segmentKinds = SegmentKind.values.asNameMap();
    final layerKinds = LayerKind.values.asNameMap();
    return TranscriptionResult(
      lang: m['lang'] as String,
      layerKind: layerKinds[m['layerKind'] as String]!,
      segments: [
        for (final s in m['segments'] as List)
          Segment(
              idx: (s['idx'] as num).toInt(),
              kind: segmentKinds[s['kind'] as String]!,
              text: s['text'] as String)
      ],
      alignments: [
        for (final a in m['alignments'] as List)
          Alignment(
              segmentIdx: (a['segmentIdx'] as num).toInt(),
              tStartMs: (a['tStartMs'] as num).toInt(),
              tEndMs: (a['tEndMs'] as num).toInt())
      ],
      layers: [
        for (final l in m['layers'] as List)
          Layer(
              segmentIdx: (l['segmentIdx'] as num).toInt(),
              lang: l['lang'] as String,
              kind: layerKinds[l['kind'] as String]!,
              text: l['text'] as String)
      ],
      mergedChunks: [
        for (final c in m['chunks'] as List)
          _decodeChunk((c as Map).cast<String, dynamic>())
      ],
    );
  }

  /// Canonical serialization — what the byte-identity property compares.
  Map<String, Object?> toJson() => {
        'lang': lang,
        'layerKind': layerKind.name,
        'segments': [
          for (final s in segments)
            {'idx': s.idx, 'kind': s.kind.name, 'text': s.text}
        ],
        'alignments': [
          for (final a in alignments)
            {
              'segmentIdx': a.segmentIdx,
              'tStartMs': a.tStartMs,
              'tEndMs': a.tEndMs
            }
        ],
        'layers': [
          for (final l in layers)
            {
              'segmentIdx': l.segmentIdx,
              'lang': l.lang,
              'kind': l.kind.name,
              'text': l.text
            }
        ],
        'chunks': [for (final c in mergedChunks) _encodeChunk(c)],
      };
}

class TranscribeEpisodeTask implements ChunkedTask {
  final PcmSource source;
  final Transcriber transcriber;

  /// Gates silent windows (the "Careless Whisper" mitigation): a window
  /// without speech still counts as a unit but adds no chunks. Null = no
  /// gating.
  final Vad? vad;

  /// Whisper's built-in task: transcribe in the source language, or
  /// translate X → English.
  final WhisperTask task;

  /// Source-language hint, passed to the engine. For a transcribe run it is
  /// also the layer language; when null, [detectLang] decides at build time.
  final String? lang;
  final LangDetector? detectLang;
  final WindowPlan plan;
  final bool wordTimings;
  final int minSegmentChars;
  final int maxSegmentChars;

  final List<TranscriptChunk> _chunks = [];
  int _nextWindowStartMs = 0;

  TranscribeEpisodeTask({
    required this.source,
    required this.transcriber,
    this.vad,
    this.task = WhisperTask.transcribe,
    this.lang,
    this.detectLang,
    WindowPlan? plan,
    this.wordTimings = true,
    this.minSegmentChars = 8,
    this.maxSegmentChars = 240,
  }) : plan = plan ?? WindowPlan();

  @override
  int get totalUnits => plan.unitCount(source.totalMs);

  int get _unitsDone => _nextWindowStartMs ~/ plan.strideMs;

  @override
  Future<void> runUnit(int unit) async {
    final startMs = plan.startMsOf(unit);
    if (startMs != _nextWindowStartMs) {
      throw StateError('unit $unit starts at ${startMs}ms but the restored '
          'state expects ${_nextWindowStartMs}ms — units must run in order '
          'from the checkpoint');
    }
    final lenMs = plan.lenMsOf(unit, source.totalMs);
    final window = await source.readWindow(startMs, lenMs);

    final speech = vad == null || await vad!.hasSpeech(window);
    if (speech) {
      // Buffer the whole window first: a mid-stream engine failure must
      // leave no partial chunks behind, because the runner will re-run this
      // unit on the same instance.
      final collected = <TranscriptChunk>[];
      await for (final c in transcriber.transcribe(
        _WindowChunkSource(window, source.sampleRate),
        lang: lang,
        task: task,
        wordTimings: wordTimings,
      )) {
        collected.add(c);
      }
      // Engine times are relative to the window it was handed; the
      // transcript lives in episode time.
      _chunks.addAll(collected.map((c) => _shift(c, startMs)));
    }
    _nextWindowStartMs = startMs + plan.strideMs;
  }

  @override
  String checkpoint() => jsonEncode({
        'nextWindowStartMs': _nextWindowStartMs,
        'chunks': [for (final c in _chunks) _encodeChunk(c)],
      });

  @override
  void restore(String checkpoint) {
    final decoded = jsonDecode(checkpoint) as Map<String, dynamic>;
    _nextWindowStartMs = (decoded['nextWindowStartMs'] as num).toInt();
    _chunks
      ..clear()
      ..addAll((decoded['chunks'] as List)
          .map((c) => _decodeChunk(c as Map<String, dynamic>)));
  }

  /// Assemble the spine rows. Only valid once every unit has committed —
  /// a partial transcript must never masquerade as the episode.
  TranscriptionResult buildResult() {
    if (_unitsDone < totalUnits) {
      throw StateError('buildResult with $_unitsDone of $totalUnits units '
          'committed — the transcript is not finished');
    }
    final merged = mergeOverlap(_chunks);
    final (resultLang, kind) = switch (task) {
      WhisperTask.translate => ('en', LayerKind.mt),
      WhisperTask.transcribe => (
          lang ?? detectLang?.call(merged) ?? 'und',
          LayerKind.transcript
        ),
    };

    final timed = segmentize(merged,
        minChars: minSegmentChars, maxChars: maxSegmentChars);
    return TranscriptionResult(
      lang: resultLang,
      layerKind: kind,
      segments: [
        for (var i = 0; i < timed.length; i++)
          Segment(idx: i, kind: SegmentKind.prose, text: timed[i].text)
      ],
      alignments: [
        for (var i = 0; i < timed.length; i++)
          Alignment(
              segmentIdx: i,
              tStartMs: timed[i].tStartMs,
              tEndMs: timed[i].tEndMs)
      ],
      layers: [
        for (var i = 0; i < timed.length; i++)
          Layer(segmentIdx: i, lang: resultLang, kind: kind, text: timed[i].text)
      ],
      mergedChunks: merged,
    );
  }
}

TranscriptChunk _shift(TranscriptChunk c, int byMs) => TranscriptChunk(
      text: c.text,
      tStartMs: c.tStartMs + byMs,
      tEndMs: c.tEndMs + byMs,
      words: c.words == null
          ? null
          : [
              for (final w in c.words!)
                WordTiming(
                    word: w.word,
                    tStartMs: w.tStartMs + byMs,
                    tEndMs: w.tEndMs + byMs)
            ],
    );

Map<String, Object?> _encodeChunk(TranscriptChunk c) => {
      'text': c.text,
      't0': c.tStartMs,
      't1': c.tEndMs,
      'words': c.words == null
          ? null
          : [
              for (final w in c.words!) [w.word, w.tStartMs, w.tEndMs]
            ],
    };

TranscriptChunk _decodeChunk(Map<String, dynamic> m) => TranscriptChunk(
      text: m['text'] as String,
      tStartMs: (m['t0'] as num).toInt(),
      tEndMs: (m['t1'] as num).toInt(),
      words: m['words'] == null
          ? null
          : [
              for (final w in m['words'] as List)
                WordTiming(
                    word: (w as List)[0] as String,
                    tStartMs: (w[1] as num).toInt(),
                    tEndMs: (w[2] as num).toInt())
            ],
    );

/// One window, presented through the engine's forward-only seam.
class _WindowChunkSource implements PcmChunkSource {
  final Float32List window;
  @override
  final int sampleRate;
  _WindowChunkSource(this.window, this.sampleRate);

  @override
  Stream<Float32List> chunks() => Stream.value(window);
}
