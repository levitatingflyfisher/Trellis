/// BrainTranslator (Campaign 8 "Babel widens" Phase 5): a second
/// Translator rung behind [TranslationJobController]'s chunked-request
/// path (`translation_job.dart`), sitting on domovoi's [Brain] interface
/// instead of an on-device ONNX session — the same reachability law the
/// rest of this app's Brain-backed features already follow (a Brain is
/// pinned explicitly by the user; this class never chooses a tier or a
/// model, it only asks whichever [Brain] its caller resolved through
/// `brainForUse()`). Marian remains the offline floor regardless of
/// whether a Brain is configured — this is an ADDITIONAL rung, never a
/// replacement, and nothing in this file constructs one on its own.
///
/// Design note, recorded rather than silently dropped: the spec named
/// "1-2 sentence overlap" between chunks as a translation-quality nicety
/// (giving the model trailing context so pronoun resolution and tone
/// stay consistent across a chunk boundary). Not implemented here — it
/// adds real complexity (tracking which sentences are context-only vs.
/// to-translate, keeping the reply's positional matching correct around
/// them) without being load-bearing to the chunking/parsing CORRECTNESS
/// contract this phase actually needs proven. A future pass can add it
/// as a prompt refinement without touching this class's public shape.
library;

import 'dart:convert';

import 'package:brain_wiring/brain_wiring.dart';

/// The Brain's reply could not be turned into a batch of translations —
/// calm and typed, the same shape brain_wiring's own
/// `GradeSuggestionFailedException`/`RecapFailedException` already use.
/// [TranslationJobController]'s chunked path treats ANY exception a
/// `translateBatch` call throws as "fail this whole chunk closed, try
/// the next one" — this type's only job is to carry a diagnosable cause
/// for logs and tests, not to change that handling.
class BrainTranslationFailedException implements Exception {
  BrainTranslationFailedException({this.cause});

  /// The underlying parse problem, for logs and tests — never shown to
  /// a reader (the reader simply sees English for the affected
  /// sentences, the same fallback law every other translator failure in
  /// this app already follows).
  final Object? cause;

  @override
  String toString() => 'BrainTranslationFailedException($cause)';
}

/// One request per chunk (the spec's own 10-20 sentences per call): a
/// numbered list of sentences in, a strict `{"translations": [...]}`
/// JSON object out, matched positionally — the SAME extract-then-parse
/// house pattern `DiscourseGrader`/`RecapGenerator` already use, via the
/// shared [extractJsonObject].
///
/// Fail-closed at the two granularities [TranslationJobController]'s
/// chunked path already expects: an unparseable or wrongly-shaped WHOLE
/// reply throws [BrainTranslationFailedException] (that entire chunk
/// fails, the next one still runs); a single array entry that is
/// missing, not a string, or blank becomes `null` in the returned list
/// (just that one sentence falls back to English — the rest of the
/// chunk still stores). The [Brain]'s own [AskException] (a consent
/// refusal, a missing key, a roadmap stub — [UnavailableTierBrain]) is
/// never caught here; it propagates to the same catch-all.
class BrainTranslator {
  BrainTranslator({
    required Brain brain,
    required this.sourceLang,
    required this.targetLang,
    required this.engine,
    Map<String, String> glossary = const {},
  })  : _brain = brain,
        _glossary = glossary;

  final Brain _brain;
  final String sourceLang;
  final String targetLang;

  /// Provenance string for `TranslationSentences.engine` — e.g.
  /// `'domovoi:stove'`, `'domovoi:byokAnthropic'`. Named by the caller
  /// (which knows the tier it resolved), not derived here — this class
  /// stays ignorant of the tier ladder entirely.
  final String engine;

  /// Optional per-work term preferences, folded into the prompt when
  /// non-empty (a proper name, a house term the model would otherwise
  /// translate literally). Absent by default.
  final Map<String, String> _glossary;

  /// Matches [TranslationJobController.translateBatch]'s own signature
  /// exactly, so `translateBatch: brainTranslator.translateBatch` threads
  /// directly — the same shape `translate: translator.translate` already
  /// follows for `MarianTranslator`.
  Future<List<String?>> translateBatch(List<String> sentences) async {
    if (sentences.isEmpty) return const [];
    final reply = await _brain.complete(_prompt(sentences));

    final Map<String, dynamic> decoded;
    try {
      final parsed = jsonDecode(extractJsonObject(reply));
      if (parsed is! Map<String, dynamic>) {
        throw const FormatException('reply JSON must be an object');
      }
      decoded = parsed;
    } on FormatException catch (error) {
      throw BrainTranslationFailedException(cause: error);
    }

    final raw = decoded['translations'];
    if (raw is! List) {
      throw BrainTranslationFailedException(
          cause: "missing 'translations' array in ${jsonEncode(decoded)}");
    }
    return [
      for (final item in raw)
        (item is String && item.trim().isNotEmpty) ? item : null,
    ];
  }

  String _prompt(List<String> sentences) {
    final numbered = [
      for (var i = 0; i < sentences.length; i++) '${i + 1}. ${sentences[i]}'
    ].join('\n');
    final glossaryBlock = _glossary.isEmpty
        ? ''
        : 'Use these EXACT translations for these terms wherever they '
            'appear:\n'
            '${_glossary.entries.map((e) => '- "${e.key}" -> "${e.value}"').join('\n')}'
            '\n\n';

    return '''
You are translating text for a reader who wants each ORIGINAL sentence
paired with a faithful translation, sentence by sentence — never a
paraphrase or a summary.

SOURCE LANGUAGE: $sourceLang
TARGET LANGUAGE: $targetLang

${glossaryBlock}Translate EACH of these ${sentences.length} numbered
sentences independently, in order:

$numbered

Reply with ONLY a JSON object, no prose, no code fences, exactly this
shape, with exactly ${sentences.length} entries in the SAME order as the
sentences above:
{"translations": ["<sentence 1's translation>", "<sentence 2's translation>", ...]}

If a sentence genuinely cannot be translated, use an empty string ""
for its entry rather than omitting it or adding commentary.
''';
  }
}
