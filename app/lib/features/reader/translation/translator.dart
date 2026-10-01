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
