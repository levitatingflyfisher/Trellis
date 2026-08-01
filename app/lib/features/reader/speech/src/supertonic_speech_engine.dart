/// The real Supertonic implementation (ADR-0007). Must stay the DEFAULT
/// branch of `supertonic_engine.dart`'s conditional export — the analyzer
/// only resolves defaults, and this file's own test analyzes against the
/// full `package:flutter_onnxruntime` API. Never imported directly by app
/// code; always through the barrel.
///
/// The inference loop (session wiring, character indexing, the
/// flow-matching denoising loop, the vocoder call) is adapted from
/// Supertone Inc.'s official Flutter example
/// (github.com/supertone-inc/supertonic, `flutter/lib/helper.dart`),
/// under its MIT License:
///
///   MIT License
///   Copyright (c) 2025 Supertone Inc.
///   Permission is hereby granted, free of charge, to any person obtaining
///   a copy of this software and associated documentation files (the
///   "Software"), to deal in the Software without restriction, including
///   without limitation the rights to use, copy, modify, merge, publish,
///   distribute, sublicense, and/or sell copies of the Software, subject
///   to the conditions in the LICENSE file in that repository.
///
/// Deliberate deviations from the upstream example, recorded here so a
/// future reader doesn't mistake them for bugs:
///  * Ported `_infer` (one already-chunked call), not `call()` — the app
///    hands this engine exactly one SENTENCE already (ADR-0006's
///    `splitSentences`), so upstream's own 300-char re-chunking and
///    inter-chunk silence splicing would insert dead air inside what the
///    pipeline believes is one clip and duplicate work already done.
///  * Batch size is fixed at 1 — one sentence per `generate()` call — so
///    every tensor below drops upstream's batch dimension complexity
///    down to a single row.
///  * `lang` is validated against the FIVE languages the shipped v2
///    weights actually cover (en/ko/es/pt/fr), not upstream's v3-example
///    31-language list — accepting a v3 language code against v2 weights
///    would silently mis-render. [SupertonicSpeechEngine] narrows this
///    further to `supertonicSupportedLangs` (English only — the one
///    voice embedding shipped and reviewed here) before a handle is ever
///    opened.
///  * Sessions load straight from the downloaded file path via
///    `OnnxRuntime().createSession(path)` — simpler than upstream's
///    asset-extraction dance (`copyModelToFile` + `createSessionFromAsset`),
///    which exists only because upstream's files are bundled Flutter
///    assets; ours are already plain files under the model store.
///  * Every intermediate `OrtValue` this file creates is disposed once
///    consumed — upstream never disposes (fine for a one-shot demo; a
///    leak here across hundreds of sentences × several denoising steps
///    on a phone).
///  * `generate()` calls are serialized one at a time by
///    [SupertonicSpeechEngine] (see that class) — concurrent `session.run`
///    calls against the same four sessions are unproven, and the
///    pipeline's synthesis lookahead can have up to three calls in
///    flight.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../supertonic_voice_handle.dart';
import '../speech_engine.dart';

/// The five languages Supertonic v2's weights were actually trained on
/// (ADR-0007) — the model-level validation gate inside the ported
/// `preprocessText`. [supertonicSupportedLangs] (English only) is the
/// narrower, entry-level gate [SupertonicSpeechEngine] applies before a
/// handle is ever opened; this one exists so the ported preprocessing
/// stays honest on its own terms if ever exercised directly.
const _v2ModelLangs = {'en', 'ko', 'es', 'pt', 'fr'};

// ---------------------------------------------------------------------
// Text preprocessing (ported from helper.dart's preprocessText/NFKD
// decomposition — verbatim data tables, house-style naming).
// ---------------------------------------------------------------------

const int _hangulSyllableBase = 0xAC00;
const int _hangulSyllableEnd = 0xD7A3;
const int _leadingJamoBase = 0x1100;
const int _vowelJamoBase = 0x1161;
const int _trailingJamoBase = 0x11A7;
const int _vowelCount = 21;
const int _trailingCount = 28;

List<int> _decomposeHangulSyllable(int codePoint) {
  if (codePoint < _hangulSyllableBase || codePoint > _hangulSyllableEnd) {
    return [codePoint];
  }
  final syllableIndex = codePoint - _hangulSyllableBase;
  final leadingIndex = syllableIndex ~/ (_vowelCount * _trailingCount);
  final vowelIndex =
      (syllableIndex % (_vowelCount * _trailingCount)) ~/ _trailingCount;
  final trailingIndex = syllableIndex % _trailingCount;
  final result = <int>[
    _leadingJamoBase + leadingIndex,
    _vowelJamoBase + vowelIndex,
  ];
  if (trailingIndex > 0) result.add(_trailingJamoBase + trailingIndex);
  return result;
}

const Map<int, List<int>> _latinDecompositions = {
  0x00C1: [0x0041, 0x0301], 0x00C9: [0x0045, 0x0301], 0x00CD: [0x0049, 0x0301],
  0x00D3: [0x004F, 0x0301], 0x00DA: [0x0055, 0x0301],
  0x00E1: [0x0061, 0x0301], 0x00E9: [0x0065, 0x0301], 0x00ED: [0x0069, 0x0301],
  0x00F3: [0x006F, 0x0301], 0x00FA: [0x0075, 0x0301],
  0x00C0: [0x0041, 0x0300], 0x00C8: [0x0045, 0x0300], 0x00CC: [0x0049, 0x0300],
  0x00D2: [0x004F, 0x0300], 0x00D9: [0x0055, 0x0300],
  0x00E0: [0x0061, 0x0300], 0x00E8: [0x0065, 0x0300], 0x00EC: [0x0069, 0x0300],
  0x00F2: [0x006F, 0x0300], 0x00F9: [0x0075, 0x0300],
  0x00C2: [0x0041, 0x0302], 0x00CA: [0x0045, 0x0302], 0x00CE: [0x0049, 0x0302],
  0x00D4: [0x004F, 0x0302], 0x00DB: [0x0055, 0x0302],
  0x00E2: [0x0061, 0x0302], 0x00EA: [0x0065, 0x0302], 0x00EE: [0x0069, 0x0302],
  0x00F4: [0x006F, 0x0302], 0x00FB: [0x0075, 0x0302],
  0x00C3: [0x0041, 0x0303], 0x00D1: [0x004E, 0x0303], 0x00D5: [0x004F, 0x0303],
  0x00E3: [0x0061, 0x0303], 0x00F1: [0x006E, 0x0303], 0x00F5: [0x006F, 0x0303],
  0x00C4: [0x0041, 0x0308], 0x00CB: [0x0045, 0x0308], 0x00CF: [0x0049, 0x0308],
  0x00D6: [0x004F, 0x0308], 0x00DC: [0x0055, 0x0308],
  0x00E4: [0x0061, 0x0308], 0x00EB: [0x0065, 0x0308], 0x00EF: [0x0069, 0x0308],
  0x00F6: [0x006F, 0x0308], 0x00FC: [0x0075, 0x0308],
  0x00C7: [0x0043, 0x0327], 0x00E7: [0x0063, 0x0327],
};

String _applyNfkdDecomposition(String text) {
  final result = <int>[];
  for (final codePoint in text.runes) {
    if (codePoint >= _hangulSyllableBase && codePoint <= _hangulSyllableEnd) {
      result.addAll(_decomposeHangulSyllable(codePoint));
    } else if (_latinDecompositions.containsKey(codePoint)) {
      result.addAll(_latinDecompositions[codePoint]!);
    } else {
      result.add(codePoint);
    }
  }
  return String.fromCharCodes(result);
}

final _emojiPattern = RegExp(
  r'[\u{1F600}-\u{1F64F}]|[\u{1F300}-\u{1F5FF}]|[\u{1F680}-\u{1F6FF}]|'
  r'[\u{1F700}-\u{1F77F}]|[\u{1F780}-\u{1F7FF}]|[\u{1F800}-\u{1F8FF}]|'
  r'[\u{1F900}-\u{1F9FF}]|[\u{1FA00}-\u{1FA6F}]|[\u{1FA70}-\u{1FAFF}]|'
  r'[\u{2600}-\u{26FF}]|[\u{2700}-\u{27BF}]|[\u{1F1E6}-\u{1F1FF}]',
  unicode: true,
);

// not-rendered: these characters are replaceAll() pattern data — text the
// model's own preprocessing strips or normalizes before synthesis, never
// drawn by the app's UI (C7-fonts, oh_fleet_conformance).
const Map<String, String> _symbolReplacements = {
  '–': '-', '‑': '-', '—': '-', '_': ' ', // not-rendered
  '“': '"', '”': '"', '‘': "'", '’': "'",
  '´': "'", '`': "'",
  '[': ' ', ']': ' ', '|': ' ', '/': ' ', '#': ' ', '→': ' ', '←': ' ', // not-rendered
};

final _terminalPunctuationPattern =
    RegExp(r'[.!?;:,\x27\x22‘’)\]}…。」』】〉》›»]$');

/// [SupertonicUnsupportedLangException] replaces upstream's raw
/// `ArgumentError` — ADR-0003's "errors are sentences" law.
String _preprocessText(String text, String lang) {
  if (!_v2ModelLangs.contains(lang)) {
    throw SupertonicUnsupportedLangException(
        'This voice cannot speak "$lang" — the model covers '
        '${_v2ModelLangs.join(', ')}.');
  }

  text = _applyNfkdDecomposition(text);
  text = text.replaceAll(_emojiPattern, '');
  for (final entry in _symbolReplacements.entries) {
    text = text.replaceAll(entry.key, entry.value);
  }
  text = text.replaceAll(RegExp(r'[♥☆♡©\\]'), '');
  text = text.replaceAll('@', ' at ');
  text = text.replaceAll('e.g.,', 'for example, ');
  text = text.replaceAll('i.e.,', 'that is, ');
  text = text.replaceAll(' ,', ',');
  text = text.replaceAll(' .', '.');
  text = text.replaceAll(' !', '!');
  text = text.replaceAll(' ?', '?');
  text = text.replaceAll(' ;', ';');
  text = text.replaceAll(' :', ':');
  text = text.replaceAll(" '", "'");
  while (text.contains('""')) {
    text = text.replaceAll('""', '"');
  }
  while (text.contains("''")) {
    text = text.replaceAll("''", "'");
  }
  while (text.contains('``')) {
    text = text.replaceAll('``', '`');
  }
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isNotEmpty && !_terminalPunctuationPattern.hasMatch(text)) {
    text += '.';
  }

  return '<$lang>$text</$lang>';
}

// ---------------------------------------------------------------------
// Small numeric helpers (ported).
// ---------------------------------------------------------------------

List<double> _flattenToDouble(dynamic value) {
  if (value is List) {
    final out = <double>[];
    for (final e in value) {
      out.addAll(_flattenToDouble(e));
    }
    return out;
  }
  return [(value as num).toDouble()];
}

/// A single Box-Muller Gaussian sample — ported verbatim from
/// `_sampleNoisyLatent`.
double _gaussianSample(math.Random random) {
  final u1 = math.max(1e-10, random.nextDouble());
  final u2 = random.nextDouble();
  return math.sqrt(-2.0 * math.log(u1)) * math.cos(2.0 * math.pi * u2);
}

// ---------------------------------------------------------------------
// The real handle.
// ---------------------------------------------------------------------

Future<SupertonicVoiceHandle> _openRealVoiceHandle(
    SupertonicVoiceFiles files) async {
  final ort = OnnxRuntime();
  final dpSession = await ort.createSession(files.durationPredictorPath);
  final textEncSession = await ort.createSession(files.textEncoderPath);
  final vectorEstSession = await ort.createSession(files.vectorEstimatorPath);
  final vocoderSession = await ort.createSession(files.vocoderPath);

  final indexerJson =
      jsonDecode(await File(files.unicodeIndexerPath).readAsString()) as List;
  final indexer = <int, int>{
    for (var i = 0; i < indexerJson.length; i++)
      if (indexerJson[i] is int && (indexerJson[i] as int) >= 0)
        i: indexerJson[i] as int,
  };

  final cfgs = jsonDecode(await File(files.ttsConfigPath).readAsString())
      as Map<String, dynamic>;
  final ae = cfgs['ae'] as Map<String, dynamic>;
  final ttl = cfgs['ttl'] as Map<String, dynamic>;
  final sampleRate = ae['sample_rate'] as int;
  final baseChunkSize = ae['base_chunk_size'] as int;
  final chunkCompressFactor = ttl['chunk_compress_factor'] as int;
  final latentDim = ttl['latent_dim'] as int;

  final styleJson = jsonDecode(await File(files.voiceStylePath).readAsString())
      as Map<String, dynamic>;
  final ttlDims =
      List<int>.from(styleJson['style_ttl']['dims'] as List);
  final dpDims = List<int>.from(styleJson['style_dp']['dims'] as List);
  final styleTtl = await OrtValue.fromList(
      Float32List.fromList(_flattenToDouble(styleJson['style_ttl']['data'])),
      ttlDims);
  final styleDp = await OrtValue.fromList(
      Float32List.fromList(_flattenToDouble(styleJson['style_dp']['data'])),
      dpDims);

  return _RealSupertonicVoiceHandle(
    dpSession: dpSession,
    textEncSession: textEncSession,
    vectorEstSession: vectorEstSession,
    vocoderSession: vocoderSession,
    indexer: indexer,
    sampleRate: sampleRate,
    baseChunkSize: baseChunkSize,
    chunkCompressFactor: chunkCompressFactor,
    latentDim: latentDim,
    styleTtl: styleTtl,
    styleDp: styleDp,
  );
}

/// The number of flow-matching denoising steps — a fixed engine constant
/// in v1 (upstream's own demo default is 8, exposed there as a UI
/// slider; Trellis has no such control surface yet, so 8 ships as the
/// one honest default rather than an invented knob).
const _totalDenoisingSteps = 8;

class _RealSupertonicVoiceHandle implements SupertonicVoiceHandle {
  final OrtSession dpSession;
  final OrtSession textEncSession;
  final OrtSession vectorEstSession;
  final OrtSession vocoderSession;
  final Map<int, int> indexer;
  final int sampleRate;
  final int baseChunkSize;
  final int chunkCompressFactor;
  final int latentDim;
  final OrtValue styleTtl;
  final OrtValue styleDp;
  final math.Random _random = math.Random();

  _RealSupertonicVoiceHandle({
    required this.dpSession,
    required this.textEncSession,
    required this.vectorEstSession,
    required this.vocoderSession,
    required this.indexer,
    required this.sampleRate,
    required this.baseChunkSize,
    required this.chunkCompressFactor,
    required this.latentDim,
    required this.styleTtl,
    required this.styleDp,
  });

  @override
  Future<SynthResult> generate(String text, {required String lang}) async {
    final processed = _preprocessText(text, lang);
    final runes = processed.runes.toList();
    final len = runes.length;
    final textIds =
        Int64List.fromList(runes.map((r) => (indexer[r] ?? 0).toInt()).toList());
    final textMask = Float32List(len)..fillRange(0, len, 1.0);

    final textIdsTensor = await OrtValue.fromList(textIds, [1, len]);
    final textMaskTensor = await OrtValue.fromList(textMask, [1, 1, len]);

    final dpResult = await dpSession.run({
      'text_ids': textIdsTensor,
      'style_dp': styleDp,
      'text_mask': textMaskTensor,
    });
    final durOnnx = (await dpResult.values.first.asFlattenedList())
        .map((e) => (e as num).toDouble())
        .toList();
    await _disposeAll(dpResult.values);
    // Upstream's speed knob (its demo divides this duration by a
    // user-set factor, default 1.05) is deliberately not ported: Trellis
    // has no reading-speed control surface, so the voice renders at
    // exactly the duration the predictor asked for.
    final totalDurationSec = durOnnx.first;

    final textEncResult = await textEncSession.run({
      'text_ids': textIdsTensor,
      'style_ttl': styleTtl,
      'text_mask': textMaskTensor,
    });
    final textEmb = textEncResult.values.first;
    await _disposeAll(textEncResult.values.where((v) => v != textEmb));

    final chunkSize = baseChunkSize * chunkCompressFactor;
    final wavLenMax = totalDurationSec * sampleRate;
    final wavLength = (totalDurationSec * sampleRate).floor();
    final latentLen = ((wavLenMax + chunkSize - 1) / chunkSize).floor();
    final latentDimTotal = latentDim * chunkCompressFactor;
    final latentLength = ((wavLength + chunkSize - 1) / chunkSize).floor();

    final noisyLatent = Float32List(latentDimTotal * latentLen);
    final latentMask = Float32List(latentLen);
    for (var t = 0; t < latentLen; t++) {
      latentMask[t] = t < latentLength ? 1.0 : 0.0;
    }
    for (var d = 0; d < latentDimTotal; d++) {
      for (var t = 0; t < latentLen; t++) {
        noisyLatent[d * latentLen + t] = _gaussianSample(_random) * latentMask[t];
      }
    }

    final latentShape = [1, latentDimTotal, latentLen];
    final latentMaskTensor = await OrtValue.fromList(latentMask, [1, 1, latentLen]);
    final totalStepTensor =
        await OrtValue.fromList(Float32List.fromList([_totalDenoisingSteps.toDouble()]), [1]);

    for (var step = 0; step < _totalDenoisingSteps; step++) {
      final noisyLatentTensor = await OrtValue.fromList(noisyLatent, latentShape);
      final currentStepTensor =
          await OrtValue.fromList(Float32List.fromList([step.toDouble()]), [1]);

      final stepResult = await vectorEstSession.run({
        'noisy_latent': noisyLatentTensor,
        'text_emb': textEmb,
        'style_ttl': styleTtl,
        'text_mask': textMaskTensor,
        'latent_mask': latentMaskTensor,
        'total_step': totalStepTensor,
        'current_step': currentStepTensor,
      });
      final denoised = (await stepResult.values.first.asFlattenedList())
          .map((e) => (e as num).toDouble())
          .toList();
      for (var i = 0; i < noisyLatent.length && i < denoised.length; i++) {
        noisyLatent[i] = denoised[i];
      }

      await noisyLatentTensor.dispose();
      await currentStepTensor.dispose();
      await _disposeAll(stepResult.values);
    }

    final finalLatentTensor = await OrtValue.fromList(noisyLatent, latentShape);
    final vocoderResult = await vocoderSession.run({'latent': finalLatentTensor});
    final wav = (await vocoderResult.values.first.asFlattenedList())
        .map((e) => (e as num).toDouble())
        .toList();

    await finalLatentTensor.dispose();
    await _disposeAll(vocoderResult.values);
    await textIdsTensor.dispose();
    await textMaskTensor.dispose();
    await textEmb.dispose();
    await latentMaskTensor.dispose();
    await totalStepTensor.dispose();

    return SynthResult(
        samples: Float32List.fromList(wav), sampleRate: sampleRate);
  }

  Future<void> _disposeAll(Iterable<OrtValue> values) async {
    for (final v in values) {
      await v.dispose();
    }
  }

  @override
  Future<void> dispose() async {
    await styleTtl.dispose();
    await styleDp.dispose();
    await dpSession.close();
    await textEncSession.close();
    await vectorEstSession.close();
    await vocoderSession.close();
  }
}

// ---------------------------------------------------------------------
// The engine (mirrors SherpaSpeechEngine's shape).
// ---------------------------------------------------------------------

/// Supertonic wrapped behind [SynthesisSpeechEngine]: one resident
/// [SupertonicVoiceHandle] per loaded voice, created lazily on the first
/// [synthesize] call and disposed on voice switch/teardown — the same
/// residency law `transcribe_core`'s whisper engine and the sherpa rung
/// before it followed (create per use, dispose explicitly; no LRU pool,
/// no timer-driven eviction).
///
/// Two things this engine adds beyond the sherpa rung's shape, both
/// because ONNX Runtime inference is asynchronous (a platform channel,
/// not a synchronous FFI call):
///  * The lazily-opened handle is cached as a `Future`, not a value —
///    `_handleFuture ??= _open()` assigns synchronously, so two
///    `synthesize()` calls racing before the handle resolves still only
///    open it once. Caching the resolved VALUE instead (`await`-then-
///    assign) would race: both callers could read null before either
///    writes.
///  * `generate()` calls are serialized through [_generationQueue] — the
///    pipeline's synthesis lookahead can have up to three `synthesize()`
///    calls in flight at once, and concurrent `session.run` calls
///    against the same four ONNX sessions are unproven.
class SupertonicSpeechEngine implements SynthesisSpeechEngine {
  final SupertonicVoiceFiles files;
  final SupertonicVoiceHandleFactory _openHandle;

  Future<SupertonicVoiceHandle>? _handleFuture;
  Future<void> _generationQueue = Future.value();

  SupertonicSpeechEngine({
    required this.files,
    SupertonicVoiceHandleFactory? openHandle,
  }) : _openHandle = openHandle ?? _openRealVoiceHandle;

  @override
  bool get canPause => true;

  @override
  Future<SynthResult> synthesize(String sentence, {String? lang}) {
    final resolvedLang = lang ?? 'en';
    if (!supertonicSupportedLangs.contains(resolvedLang)) {
      throw SupertonicUnsupportedLangException(
          'This voice cannot speak "$resolvedLang" — try the system voice.');
    }

    final result = _generationQueue.then((_) async {
      final handle = await (_handleFuture ??= _open());
      return handle.generate(sentence, lang: resolvedLang);
    });
    // Chain the NEXT call after this one settles either way — a failed
    // synthesis must not wedge every call queued behind it.
    _generationQueue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<SupertonicVoiceHandle> _open() async {
    _checkFilesPresent();
    try {
      return await _openHandle(files);
    } on SupertonicVoiceMissingFilesException {
      rethrow;
    } catch (e) {
      throw SupertonicNativeInitException(
          'The downloaded voice could not be started ($e). Try '
          're-downloading it in Models.');
    }
  }

  void _checkFilesPresent() {
    for (final path in [
      files.durationPredictorPath,
      files.textEncoderPath,
      files.vectorEstimatorPath,
      files.vocoderPath,
      files.unicodeIndexerPath,
      files.ttsConfigPath,
      files.voiceStylePath,
    ]) {
      if (!File(path).existsSync()) {
        throw SupertonicVoiceMissingFilesException(
            'This voice is missing a file it needs — try re-downloading '
            'it in Models.');
      }
    }
  }

  @override
  Future<void> dispose() async {
    final f = _handleFuture;
    _handleFuture = null;
    if (f == null) return;
    // Let any in-flight generation settle first — closing ONNX sessions
    // under a live `run` is a native-level gamble. The queue already
    // swallows generation errors, so this await cannot throw.
    await _generationQueue;
    final SupertonicVoiceHandle handle;
    try {
      handle = await f;
    } catch (_) {
      // The open itself failed; there are no sessions to release, and
      // dispose is not the place to re-raise a failure synthesize()
      // already surfaced.
      return;
    }
    await handle.dispose();
  }
}
