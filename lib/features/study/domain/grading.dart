// Auto-grading and grade suggestion (pure functions).
//
// These power the grading model described in docs/curriculum-format.md:
//
//   * cloze / discrimination  -> auto-graded (normalized exact match, or the
//     correct choice index). A definitive right/wrong.
//   * qa / procedure          -> there is no machine "right answer", so we
//     measure how many of the author's `acceptable` keyword anchors appear in
//     the learner's typed response and turn that coverage fraction into a
//     *suggested* [Grade]. The learner then self-rates honestly (the rubric is
//     shown after the attempt); that self-rating is what actually drives the
//     SRS via scheduleSm2.
//
// Everything here is pure and deterministic: same inputs always produce the
// same output. No I/O, no clocks, no mutation of the inputs.

import 'package:trellis/features/curriculum/domain/models.dart';

/// Canonicalize free-text for comparison: lowercase, trim the ends, and
/// collapse every run of internal whitespace (spaces, tabs, newlines) to a
/// single space.
///
/// This is the single normalization used everywhere in this file so that
/// matching is consistently case-insensitive and whitespace-insensitive.
String normalizeAnswer(String s) =>
    s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

/// Auto-grade a [ClozeItem].
///
/// Returns `true` iff, for every blank key in [ClozeItem.answers], the
/// learner's [responses] contains that key and its (normalized) value matches
/// the (normalized) expected answer.
///
/// A missing response key counts as wrong (the learner left a blank empty).
/// Extra, unexpected keys in [responses] are ignored — only the item's own
/// blanks are graded.
bool gradeCloze(ClozeItem item, Map<String, String> responses) {
  for (final entry in item.answers.entries) {
    final String? response = responses[entry.key];
    if (response == null) return false; // missing blank -> wrong
    if (normalizeAnswer(response) != normalizeAnswer(entry.value)) {
      return false;
    }
  }
  return true;
}

/// Auto-grade a [DiscriminationItem]: `true` iff the learner picked the
/// item's [DiscriminationItem.correctIndex].
bool gradeDiscrimination(DiscriminationItem item, int chosenIndex) =>
    chosenIndex == item.correctIndex;

/// Fraction (0.0..1.0) of [acceptable] keyword anchors that appear in
/// [response].
///
/// Both the anchors and the response are normalized (see [normalizeAnswer]),
/// and each anchor is matched as a substring of the normalized response. The
/// result is `(anchors found) / (total anchors)`.
///
/// With no anchors there is nothing to measure, so this returns `0.0` (rather
/// than dividing by zero) — callers treat "no coverage signal" as the lowest
/// suggestion.
double keywordCoverage(List<String> acceptable, String response) {
  final String haystack = normalizeAnswer(response);
  var total = 0;
  var found = 0;
  for (final anchor in acceptable) {
    final a = normalizeAnswer(anchor);
    if (a.isEmpty) continue; // an empty anchor matches everything — skip it
    total++;
    if (haystack.contains(a)) found++;
  }
  return total == 0 ? 0.0 : found / total;
}

/// Turn a keyword-[coverage] fraction (0.0..1.0) into a *suggested* [Grade]
/// for a qa/procedure self-rating.
///
/// Thresholds:
///   * `<= 0.0`  -> [Grade.again] (nothing recalled)
///   * `< 0.5`   -> [Grade.hard]
///   * `< 0.85`  -> [Grade.good]
///   * otherwise -> [Grade.easy]
Grade suggestGrade(double coverage) {
  if (coverage <= 0.0) return Grade.again;
  if (coverage < 0.5) return Grade.hard;
  if (coverage < 0.85) return Grade.good;
  return Grade.easy;
}
