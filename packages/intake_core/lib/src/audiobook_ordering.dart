/// Audiobook file playback order (ADR-0013, Campaign 7). A folder of MP3s
/// exported "1, 2, 3, …, 10, 11" sorts wrong under a plain string compare
/// ("10" lands before "2"); natural sort compares runs of digits by value
/// instead of by character, which is the actual fix for that actual bug.
library;

final _runRe = RegExp(r'\d+|\D+');

/// Splits [s] into alternating digit/non-digit runs — "CD1/track10.mp3"
/// becomes `["CD", "1", "/track", "10", ".mp3"]`.
List<String> _runs(String s) => [for (final m in _runRe.allMatches(s)) m[0]!];

bool _isDigits(String run) => run.isNotEmpty && run.codeUnits.every(
      (c) => c >= 0x30 && c <= 0x39,
    );

/// The natural-order comparator itself, exposed for callers sorting
/// something richer than a bare filename (e.g. a picked-file record that
/// carries both a display name and a filesystem path, where two different
/// files can share a display name — a plain `Map<name, …>` would collide).
/// `list.sort((a, b) => naturalCompareAudiobookNames(a.name, b.name))`.
int naturalCompareAudiobookNames(String a, String b) {
  final ra = _runs(a);
  final rb = _runs(b);
  final n = ra.length < rb.length ? ra.length : rb.length;
  for (var i = 0; i < n; i++) {
    final ta = ra[i];
    final tb = rb[i];
    if (_isDigits(ta) && _isDigits(tb)) {
      final cmp = BigInt.parse(ta).compareTo(BigInt.parse(tb));
      if (cmp != 0) return cmp;
      // Equal numeric value: fewer leading zeros (the "plainer" spelling)
      // sorts first — a tie-break, never load-bearing for real filenames.
      if (ta.length != tb.length) return ta.length.compareTo(tb.length);
    } else {
      final cmp = ta.toLowerCase().compareTo(tb.toLowerCase());
      if (cmp != 0) return cmp;
    }
  }
  return ra.length.compareTo(rb.length);
}

/// Sorts [fileNames] by natural order: digit runs compare numerically
/// (ignoring leading zeros), everything else compares case-insensitively.
/// Pure and total — no filename can throw, including one with no digits at
/// all. Returns a new list; [fileNames] is untouched.
List<String> naturalSortAudiobookFiles(List<String> fileNames) {
  final sorted = [...fileNames];
  sorted.sort(naturalCompareAudiobookNames);
  return sorted;
}

/// One file's disc/track tag, when known. Phase 1 of Campaign 7 wires no
/// probe that ever populates one of these — every real call site passes
/// the default empty map — but the ordering law itself is real: this type
/// and [orderAudiobookFiles] exist so a future metadata probe has a tested
/// door to land in, not a surface to invent from scratch (see ADR-0013 for
/// why the probe itself was deferred).
class AudioTrackTag {
  final int? disc;
  final int? track;
  const AudioTrackTag({this.disc, this.track});
}

/// Orders [fileNames] for playback: disc/track tags win when EVERY file in
/// [fileNames] has one in [tags] with a non-null [AudioTrackTag.track] — a
/// disc-major, track-minor sort, with a missing disc treated as disc 1 (the
/// common single-disc case, so a book that's never tagged with a disc
/// number still sorts correctly by track alone). A file with no [disc] and
/// no [track] set is the same as an untagged file — no fabricated order.
///
/// If even one file lacks a track number, the whole tag set is distrusted
/// and [naturalSortAudiobookFiles] decides instead — a PARTIAL numeric
/// order (three of five files trustworthy, two not) would silently
/// interleave real tags with an arbitrary map-iteration order for the
/// rest, which is worse than the honest, total fallback.
List<String> orderAudiobookFiles(
  List<String> fileNames, {
  Map<String, AudioTrackTag> tags = const {},
}) {
  final allTagged =
      fileNames.isNotEmpty && fileNames.every((n) => tags[n]?.track != null);
  if (!allTagged) return naturalSortAudiobookFiles(fileNames);
  final sorted = [...fileNames];
  sorted.sort((a, b) {
    final ta = tags[a]!;
    final tb = tags[b]!;
    final discCmp = (ta.disc ?? 1).compareTo(tb.disc ?? 1);
    if (discCmp != 0) return discCmp;
    return ta.track!.compareTo(tb.track!);
  });
  return sorted;
}

final _trailingTrackNumberRe = RegExp(r'[\s_-]+\(?\d+\)?$');

/// A best-effort book title guessed from [orderedFileNames] (already in
/// playback order — the FIRST file names the book, matching how an
/// audiobook's opening track is usually titled after the book itself, not
/// "Chapter 1"). Always editable by the caller (ADR-0013) — this only
/// needs to be a reasonable starting point, not a correct one: the
/// extension and a trailing track-number-shaped tail ("- 01", "_01",
/// "(01)") are stripped, nothing more. Empty input or an empty result
/// falls back to a named placeholder rather than an empty text field.
String defaultAudiobookTitle(List<String> orderedFileNames) {
  if (orderedFileNames.isEmpty) return 'Untitled audiobook';
  final first = orderedFileNames.first;
  final dot = first.lastIndexOf('.');
  final base = dot <= 0 ? first : first.substring(0, dot);
  var guess = base.replaceFirst(_trailingTrackNumberRe, '').trim();
  // A name that was ONLY a track number ("01.mp3") strips to nothing
  // useful either way — treat it the same as an empty guess.
  if (RegExp(r'^\d+$').hasMatch(guess)) guess = '';
  return guess.isEmpty ? 'Untitled audiobook' : guess;
}
