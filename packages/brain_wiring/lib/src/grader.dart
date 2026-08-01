/// Discourse grading: a rubric-anchored critique of a free-recall
/// attempt, with a *suggested* grade.
///
/// Suggestion-only by contract — the type is named [SuggestedGrading]
/// because that is all it is. The learner's own tap drives the SRS
/// (study_core's grading law, kept even with an LLM judge available);
/// the app may pre-highlight the suggested button, nothing more.
library;

import 'dart:convert';

import 'package:brain_wiring/src/provenance.dart';
import 'package:brain_wiring/src/reply_json.dart';
import 'package:brain_wiring/src/user_gesture.dart';
import 'package:domovoi/domovoi.dart' show Brain;
import 'package:study_core/study_core.dart' show Grade;

/// A critique plus a suggested [Grade]. Never written to the scheduler
/// by this package — there is no API here that could.
class SuggestedGrading {
  const SuggestedGrading({
    required this.critique,
    required this.suggestedGrade,
    required this.provenance,
  });

  /// A short, rubric-anchored critique for the learner to read.
  final String critique;

  /// The model's suggestion. The learner decides.
  final Grade suggestedGrade;

  /// Which Brain tier + model wrote the critique.
  final Provenance provenance;
}

/// The model's critique came back unusable. Calm and typed; the learner
/// simply self-rates the way they would with no Brain at all.
class GradeSuggestionFailedException implements Exception {
  GradeSuggestionFailedException({this.cause});

  /// Displayable, in the interface's voice.
  final String message =
      'The model could not write a critique for this attempt — rate it '
      'yourself as usual.';

  /// The underlying parse problem, for logs and tests.
  final Object? cause;

  @override
  String toString() => 'GradeSuggestionFailedException($cause)';
}

class DiscourseGrader {
  DiscourseGrader({required Brain brain, required this.provenance})
      : _brain = brain;

  final Brain _brain;

  /// Stamped onto every [SuggestedGrading]; pair it with the injected
  /// Brain (e.g. `AnthropicBrain.provenance`).
  final Provenance provenance;

  /// Critiques [answer] against [rubric] and suggests a grade.
  ///
  /// [question] is optional context (the qa/procedure prompt).
  /// [userGesture] is required with no default: inference never runs
  /// unprompted (ADR-0003 law 4).
  ///
  /// Throws [GradeSuggestionFailedException] on an unusable reply; the
  /// Brain's own `AskException`s propagate untouched.
  Future<SuggestedGrading> gradeFreeRecall({
    required String rubric,
    required String answer,
    required UserGesture userGesture,
    String? question,
  }) async {
    final reply = await _brain.complete(_prompt(
      rubric: rubric,
      answer: answer,
      question: question,
    ));

    final Map<String, dynamic> decoded;
    try {
      final parsed = jsonDecode(extractJsonObject(reply));
      if (parsed is! Map<String, dynamic>) {
        throw const FormatException('reply JSON must be an object');
      }
      decoded = parsed;
    } on FormatException catch (error) {
      throw GradeSuggestionFailedException(cause: error);
    }

    final critique = decoded['critique'];
    final gradeRaw = decoded['suggestedGrade'];
    if (critique is! String || critique.trim().isEmpty) {
      throw GradeSuggestionFailedException(
          cause: "missing 'critique' in ${jsonEncode(decoded)}");
    }
    if (gradeRaw is! String) {
      throw GradeSuggestionFailedException(
          cause: "missing 'suggestedGrade' in ${jsonEncode(decoded)}");
    }
    final grade = Grade.values.asNameMap()[gradeRaw.toLowerCase()];
    if (grade == null) {
      throw GradeSuggestionFailedException(
          cause: "unknown suggestedGrade '$gradeRaw'");
    }

    return SuggestedGrading(
      critique: critique,
      suggestedGrade: grade,
      provenance: provenance,
    );
  }

  String _prompt({
    required String rubric,
    required String answer,
    String? question,
  }) => '''
You are a study coach reviewing one free-recall attempt. Your grade is a
SUGGESTION only — the learner self-rates, and their rating (not yours)
drives the schedule. Write a brief, kind, rubric-anchored critique: name
what the answer got right and the one most important gap, in at most
three sentences. No praise padding, no score theater.

${question == null ? '' : 'QUESTION:\n$question\n\n'}RUBRIC:
$rubric

LEARNER'S ANSWER:
$answer

Reply with ONLY a JSON object, no prose, no code fences:
{"critique": "<your critique>", "suggestedGrade": "again|hard|good|easy"}
''';
}
