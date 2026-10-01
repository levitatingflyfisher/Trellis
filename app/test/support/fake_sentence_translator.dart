import 'dart:async';

import 'package:trellis/features/reader/translation/translator.dart';

/// A [SentenceTranslator] that answers with [translateFn], records every
/// call, and can be told to never answer call [holdAt] (0-based): the
/// sentence a killed process was in the middle of.
class FakeSentenceTranslator implements SentenceTranslator {
  final String Function(String sentence) translateFn;
  final int? holdAt;
  final List<String> calls = [];
  bool disposed = false;

  FakeSentenceTranslator(this.translateFn, {this.holdAt});

  @override
  Future<String> translate(String sentence) {
    calls.add(sentence);
    if (calls.length - 1 == holdAt) return Completer<String>().future;
    return Future.value(translateFn(sentence));
  }

  @override
  Future<void> dispose() async => disposed = true;
}
