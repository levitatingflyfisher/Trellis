/// The LLM seam, distillation, and discourse layer (proposal-2 §7).
///
/// One seam ([Brain], re-exported from domovoi), a pure tier model with
/// explicit user-pinned selection, a BYOK Anthropic Brain over an
/// injectable HTTP seam, the transcript-to-`.ohcourse` Distiller whose
/// invariant is "must pass study_core's strict parser before save",
/// suggestion-only free-recall grading, and provenance stamping.
///
/// Two laws are type-enforced here:
///  * every inference entry point requires an explicit [UserGesture]
///    (ADR-0003 law 4 — no unprompted inference);
///  * grading returns a [SuggestedGrading] — the learner's tap drives
///    the SRS, never the model (study_core's grading law).
///
/// domovoi note: `package:domovoi/domovoi.dart` also exports io-flavoured
/// members (resumable transfer, stove server). This package imports the
/// barrel but uses only [Brain] and [AskException]; dart:io resolves to
/// unsupported stubs on web compiles, so the import stays portable.
library;

export 'package:domovoi/domovoi.dart' show Brain, AskException;

export 'src/anthropic_brain.dart';
export 'src/brain_http.dart';
export 'src/discourse.dart';
export 'src/distiller.dart';
export 'src/grader.dart';
export 'src/provenance.dart';
export 'src/tier.dart';
export 'src/user_gesture.dart';
