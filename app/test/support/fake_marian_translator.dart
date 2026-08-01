/// A fake behind a REAL [MarianTranslator] (ADR-0008 "Babel"): unlike
/// [SynthesisSpeechEngine] (an interface a test can fake outright),
/// `resolveTranslator`'s DI point is the concrete `MarianTranslator`
/// class, so reader-level tests build a real one over
/// [FakeMarianModelHandle] — the same boundary marian_translator_test.dart
/// drives — rather than faking a class ReaderScreen never actually holds.
library;

import 'dart:io';

import 'package:trellis/features/reader/translation/marian_engine.dart';

class FakeMarianModelHandle implements MarianModelHandle {
  final String Function(String sentence) translateFn;
  final List<String> calls = [];
  bool disposed = false;

  FakeMarianModelHandle(this.translateFn);

  @override
  Future<String> translate(String sentence) async {
    calls.add(sentence);
    return translateFn(sentence);
  }

  @override
  Future<void> dispose() async => disposed = true;
}

/// Writes the four placeholder files [MarianTranslator]'s presence check
/// needs under [dir] (content is irrelevant — the fake handle factory
/// never parses them) and returns the paths.
MarianTranslatorFiles fakeMarianTranslatorFiles(Directory dir) {
  for (final name in [
    'encoder_model_quantized.onnx',
    'decoder_model_merged_quantized.onnx',
    'source.spm',
    'vocab.json',
  ]) {
    File('${dir.path}/$name').writeAsBytesSync(const [1, 2, 3]);
  }
  return MarianTranslatorFiles(
    encoderPath: '${dir.path}/encoder_model_quantized.onnx',
    decoderMergedPath: '${dir.path}/decoder_model_merged_quantized.onnx',
    sourceSpmPath: '${dir.path}/source.spm',
    vocabPath: '${dir.path}/vocab.json',
  );
}

/// A ready-to-use [MarianTranslator] whose "translation" is deterministic
/// and synchronous-fast — `translateFn` defaults to a recognizable
/// `'ES: <sentence>'` tag so a test can assert on it without caring about
/// real Spanish output.
MarianTranslator fakeMarianTranslator(Directory dir,
        {String Function(String sentence)? translateFn}) =>
    MarianTranslator(
      files: fakeMarianTranslatorFiles(dir),
      openHandle: (_) async =>
          FakeMarianModelHandle(translateFn ?? (s) => 'ES: $s'),
    );
