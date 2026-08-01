/// Cross-feed dedup (Campaign 5 Phase 3): two river items are duplicates
/// when their canonical URLs match after tracker-parameter stripping
/// (comms_core's [canonicalizeForDedup]) OR their titles are
/// exact-normalized equal AND published within 48h. The YOUNGER
/// duplicate is suppressed — kept in the database, hidden from the
/// river, its reason recorded (never deleted: "hidden", not "gone").
///
/// Law: dedup NEVER suppresses two items from the SAME feed — a host
/// reposting its own item is the author's editorial choice, not noise.
///
/// Pure and pairwise, not a transitive-closure clustering pass: a chain
/// of three-or-more near-duplicates each resolves independently against
/// whichever pair is found first. That is the honest scope for a
/// personal river's size; nothing in the spec asks for cluster
/// resolution.
library;

import 'package:comms_core/comms_core.dart';

const _fortyEightHoursMs = 48 * 60 * 60 * 1000;

/// One river item as dedup sees it: identity, feed (for the same-feed
/// exemption), the URL to canonicalize, the title to normalize, and when
/// it published (both the 48h window and "which one is younger").
typedef DedupCandidate = ({
  int workId,
  int feedId,
  String? sourceUrl,
  String title,
  int publishedAtMs,
});

typedef DedupVerdict = ({String reason, int canonicalWorkId});

final _whitespace = RegExp(r'\s+');

/// Exact-normalized: trimmed, lowercased, internal whitespace runs
/// collapsed to one space. Not a fuzzy match — "Aurora  Season" and
/// "aurora season" are equal; "Aurora Season, Part 2" is not.
String _normalizeTitle(String title) =>
    title.trim().toLowerCase().replaceAll(_whitespace, ' ');

/// Evaluates every pair of [candidates] and returns a map from a
/// suppressed (younger) workId to its verdict — reason and the
/// canonical (older) workId it duplicates. Candidates absent from the
/// result are not suppressed.
Map<int, DedupVerdict> findDuplicates(List<DedupCandidate> candidates) {
  final suppressed = <int, DedupVerdict>{};
  for (var i = 0; i < candidates.length; i++) {
    for (var j = i + 1; j < candidates.length; j++) {
      final a = candidates[i];
      final b = candidates[j];
      if (a.feedId == b.feedId) continue; // reposts are the author's choice

      final reason = _matchReason(a, b);
      if (reason == null) continue;

      final aIsYounger = a.publishedAtMs != b.publishedAtMs
          ? a.publishedAtMs > b.publishedAtMs
          : a.workId > b.workId;
      final younger = aIsYounger ? a : b;
      final older = aIsYounger ? b : a;
      suppressed.putIfAbsent(
          younger.workId,
          () => (reason: reason, canonicalWorkId: older.workId));
    }
  }
  return suppressed;
}

String? _matchReason(DedupCandidate a, DedupCandidate b) {
  final au = a.sourceUrl, bu = b.sourceUrl;
  if (au != null &&
      au.isNotEmpty &&
      bu != null &&
      bu.isNotEmpty &&
      canonicalizeForDedup(au) == canonicalizeForDedup(bu)) {
    return 'url';
  }
  final at = _normalizeTitle(a.title), bt = _normalizeTitle(b.title);
  if (at.isNotEmpty &&
      at == bt &&
      (a.publishedAtMs - b.publishedAtMs).abs() <= _fortyEightHoursMs) {
    return 'title';
  }
  return null;
}
