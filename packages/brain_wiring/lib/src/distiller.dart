/// The Distiller: transcript/text in, a saveable `.ohcourse` out, via
/// whichever [Brain] the user pinned.
///
/// THE invariant (proposal-2 §7, tested): any Brain-generated course
/// must pass study_core's strict parser — schema, prereq referential
/// integrity, cycle rejection — *and* the distill-time discourse
/// contract *before* it is saved. Up to [Distiller.maxRepairRounds]
/// repair rounds feed the parser's path-qualified errors back to the
/// model; after that, a visible typed failure. Never a half-imported
/// course.
library;

import 'dart:convert';

import 'package:brain_wiring/src/discourse.dart';
import 'package:brain_wiring/src/provenance.dart';
import 'package:brain_wiring/src/reply_json.dart';
import 'package:brain_wiring/src/user_gesture.dart';
import 'package:domovoi/domovoi.dart' show AskException, Brain;
import 'package:study_core/study_core.dart';

/// A course that made it through the gate, ready to save.
class DistilledCourse {
  const DistilledCourse({
    required this.course,
    required this.ohcourseJson,
    required this.discourse,
    required this.provenance,
    required this.repairRounds,
  });

  /// The parsed course — proof the strict parser accepted it.
  final Course course;

  /// The exact text to write to disk. Re-parsing this string is
  /// guaranteed to succeed; it carries the discourse items and the
  /// provenance stamp.
  final String ohcourseJson;

  /// Node id → the 1-2 discourse items baked into that node.
  final Map<String, List<DiscourseItem>> discourse;

  /// Which Brain tier + model generated this course.
  final Provenance provenance;

  /// How many repair rounds it took (0 = clean first pass).
  final int repairRounds;
}

/// The visible, typed end of the line: the model could not produce a
/// parseable course within the repair budget. Show [message]; keep
/// [lastError] for the details screen and the logs.
class DistillFailedException implements Exception {
  DistillFailedException({
    required this.attempts,
    required this.lastError,
  });

  /// Calm and displayable, in the interface's voice.
  final String message =
      'The model could not produce a valid course from this source — '
      'nothing was saved. Try again, or try a different Brain.';

  /// Total Brain calls made (initial + repair rounds).
  final int attempts;

  /// The last path-qualified parser/discourse error.
  final FormatException lastError;

  @override
  String toString() =>
      'DistillFailedException(after $attempts attempts: '
      '${lastError.message})';
}

class Distiller {
  Distiller({
    required Brain brain,
    required this.provenance,
    this.maxRepairRounds = 3,
  }) : _brain = brain;

  final Brain _brain;

  /// Stamped into every distilled course. The caller pairs it with the
  /// Brain it injects (e.g. `AnthropicBrain.provenance`).
  final Provenance provenance;

  /// Repair rounds after the initial generation before giving up.
  final int maxRepairRounds;

  /// Distills [source] (a transcript, article, or pasted text) into a
  /// validated `.ohcourse`.
  ///
  /// [userGesture] is required with no default: inference never runs
  /// unprompted (ADR-0003 law 4).
  ///
  /// Throws [DistillFailedException] when the repair budget runs out,
  /// and lets the Brain's own [AskException]s propagate untouched —
  /// a cold stove or a rate limit is not a formatting problem, and
  /// retrying it blind would be.
  Future<DistilledCourse> distill({
    required String source,
    required UserGesture userGesture,
  }) async {
    var prompt = _distillPrompt(source);
    FormatException lastError =
        const FormatException('no attempt was made');
    var attempts = 0;

    while (attempts <= maxRepairRounds) {
      final reply = await _brain.complete(prompt);
      attempts++;
      try {
        return _validate(reply, repairRounds: attempts - 1);
      } on FormatException catch (error) {
        lastError = error;
        prompt = _repairPrompt(reply, error);
      }
    }
    throw DistillFailedException(attempts: attempts, lastError: lastError);
  }

  /// Runs the whole gate: strict parse, discourse contract, provenance
  /// stamping — and then re-parses the exact text that will be saved,
  /// so nothing between here and disk can drift.
  DistilledCourse _validate(String reply, {required int repairRounds}) {
    final jsonText = extractJsonObject(reply);
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException catch (e) {
      throw FormatException('invalid JSON: ${e.message}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
          'top-level JSON must be an object (a course)');
    }

    // Gate 1: the strict study_core parser (schema, prereq integrity,
    // cycle rejection). Gate 2: the distill-time discourse contract.
    parseCourse(decoded);
    validateDistilledDiscourse(decoded);

    // Stamp provenance and freeze the exact bytes that will be saved.
    decoded['provenance'] = provenance.toJson();
    final ohcourseJson =
        const JsonEncoder.withIndent('  ').convert(decoded);

    // The invariant, applied to the final text itself: what we hand back
    // is what the importer will accept.
    final course = parseCourseString(ohcourseJson);
    return DistilledCourse(
      course: course,
      ohcourseJson: ohcourseJson,
      discourse: readCourseDiscourse(decoded),
      provenance: provenance,
      repairRounds: repairRounds,
    );
  }

  /// The system prompt encodes Matuschak's prompt properties —
  /// focused, precise, consistent, tractable, effortful — and the
  /// distill-time discourse contract, alongside the strict `.ohcourse`
  /// schema the reply must satisfy.
  String _distillPrompt(String source) => '''
You are a curriculum distiller for a spaced-repetition study app.
Turn the SOURCE below into one course as a single JSON object — output
ONLY that JSON object, no prose, no code fences.

Write every retrieval item to Andy Matuschak's prompt properties:
- focused: one idea per item, never two;
- precise: an unambiguous cue with exactly one defensible answer;
- consistent: the same cue should always pull the same answer;
- tractable: answerable from the node's intake alone, almost always
  correctly;
- effortful: the answer must be retrieved from memory, never inferable
  from the cue's wording.

Schema (schemaVersion "1.0"):
{
  "schemaVersion": "1.0",
  "id": "<kebab-case-id>",
  "title": "<course title>",
  "nodes": [
    {
      "id": "<node-id>",
      "title": "<concept title>",
      "summary": "<one sentence>",
      "prereqs": ["<ids of nodes this one builds on>"],
      "intake": "<a substantial first-principles prose passage>",
      "items": [ 1-4 items, each one of:
        {"id","type":"cloze","rung":1,"text":"... {{c1::answer}} ...","answers":{"c1":"answer"}},
        {"id","type":"qa","rung":3,"prompt","answer","acceptable":["keyword anchors"],"rubric"},
        {"id","type":"discrimination","rung":2,"prompt","choices":[...],"correctIndex":0,"explanation"},
        {"id","type":"procedure","rung":4,"prompt","steps":[...],"rubric"}
      ],
      "discourse": [ REQUIRED, 1-2 items:
        {"kind":"socratic","prompt":"<a Socratic follow-up probing one gap>"},
        {"kind":"explain_back","prompt":"<a teach-it-back-in-your-own-words prompt>"}
      ]
    }
  ]
}

Hard rules:
- every "prereqs" entry names an existing node id; no cycles;
- prerequisite concepts come before the concepts that build on them;
- every node carries "discourse" with 1-2 items and no repeated kind —
  these let a learner study with construction even on a device with no
  model at all;
- item ids are unique across the course; rung is 1 (high cue) to 4
  (free generation).

SOURCE:
$source
''';

  String _repairPrompt(String previousReply, FormatException error) => '''
Your previous course JSON was rejected by the strict validator.

Validator error (path-qualified):
${error.message}

Your previous reply:
$previousReply

Fix the error and return the COMPLETE corrected course as a single JSON
object — output ONLY the JSON object, no prose, no code fences. Keep
everything that was already valid, including the schema rules and the
required per-node "discourse" items (1-2 per node, kinds "socratic" /
"explain_back", no repeats).
''';
}
