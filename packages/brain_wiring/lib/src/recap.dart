/// Campaign 4 Phase 4's "Catch me up?" recap: a short, spoiler-safe
/// summary of a work-in-progress, via whichever [Brain] the user pinned.
///
/// Spoiler-safety is a TWO-layer guarantee, deliberately: the caller must
/// hand in only pre-position text (the app's own `preCursorText` enforces
/// this before any prompt is built, tested in isolation there), and the
/// prompt itself also instructs the model never to invent or reference
/// what it was not shown — belt and suspenders, since a model asked
/// nicely can still fill a gap from its own training data if the prompt
/// leaves room for it.
library;

import 'dart:convert';

import 'package:brain_wiring/src/provenance.dart';
import 'package:brain_wiring/src/reply_json.dart';
import 'package:brain_wiring/src/user_gesture.dart';
import 'package:domovoi/domovoi.dart' show Brain;

/// A recap the model wrote, plus who wrote it. Never persisted — the
/// caller shows [summary] in a sheet and lets it go when the sheet closes.
class Recap {
  const Recap({required this.summary, required this.provenance});

  /// A short, spoiler-safe "so far" summary — a sheet's worth, not a page.
  final String summary;

  /// Which Brain tier + model wrote it, so the sheet can name its source.
  final Provenance provenance;
}

/// The model could not produce a usable recap. Calm and typed; the reader
/// simply keeps reading, the same as if the offer had never appeared.
class RecapFailedException implements Exception {
  RecapFailedException({this.cause});

  /// Displayable, in the interface's voice.
  final String message =
      'The model could not write a recap right now — pick up reading '
      'where you left off.';

  /// The underlying parse problem, for logs and tests.
  final Object? cause;

  @override
  String toString() => 'RecapFailedException($cause)';
}

class RecapGenerator {
  RecapGenerator({required Brain brain, required this.provenance})
      : _brain = brain;

  final Brain _brain;

  /// Stamped onto every [Recap]; pair it with the injected Brain (e.g.
  /// `AnthropicBrain.provenance`).
  final Provenance provenance;

  /// Summarizes [textSoFar] — already filtered to text strictly before
  /// the reader's own cursor — for a reader reopening [title].
  ///
  /// [userGesture] is required with no default: inference never runs
  /// unprompted (ADR-0003 law 4). Throws [RecapFailedException] on an
  /// unusable reply; the Brain's own `AskException`s propagate untouched.
  Future<Recap> recap({
    required String title,
    required String textSoFar,
    required UserGesture userGesture,
  }) async {
    final reply =
        await _brain.complete(_prompt(title: title, textSoFar: textSoFar));

    final Map<String, dynamic> decoded;
    try {
      final parsed = jsonDecode(extractJsonObject(reply));
      if (parsed is! Map<String, dynamic>) {
        throw const FormatException('reply JSON must be an object');
      }
      decoded = parsed;
    } on FormatException catch (error) {
      throw RecapFailedException(cause: error);
    }

    final summary = decoded['recap'];
    if (summary is! String || summary.trim().isEmpty) {
      throw RecapFailedException(
          cause: "missing 'recap' in ${jsonEncode(decoded)}");
    }

    return Recap(summary: summary, provenance: provenance);
  }

  String _prompt({required String title, required String textSoFar}) => '''
You are reminding a reader what has happened so far in "$title", right
before they continue reading. Write a brief "catch me up" recap — 2 to 4
sentences — covering only events, facts and ideas that appear in the
text below.

You have NOT been shown what comes after this point in the work. Do not
guess, invent, or reference anything beyond the text given — if you are
unsure whether something happens later, leave it out.

TEXT SO FAR:
$textSoFar

Reply with ONLY a JSON object, no prose, no code fences:
{"recap": "<your recap>"}
''';
}
