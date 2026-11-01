/// What a translation run needs from an engine: one sentence in, one out,
/// and a way to free whatever it holds. [MarianTranslator] is the real
/// one; tests pass a fake.
library;

abstract interface class SentenceTranslator {
  Future<String> translate(String sentence);

  /// Frees the engine's native sessions. A run calls this as soon as its
  /// pass is over: two resident Marian models are several hundred MB.
  Future<void> dispose();
}

/// An engine that translates many sentences in one request (a brain: one
/// request covering 10 to 20 sentences costs far less than one each). A
/// run hands it whole chunks and stores [engine] on every row it writes,
/// so where a translation was made is never lost.
abstract interface class BatchSentenceTranslator implements SentenceTranslator {
  /// One translation per sentence, in order; null fails just that one.
  Future<List<String?>> translateBatch(List<String> sentences);

  /// Provenance for `TranslationSentences.engine`.
  String get engine;
}
