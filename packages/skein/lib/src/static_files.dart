/// The traversal guard (law 5). Two layers, because dart:io's own [Uri]
/// parsing already collapses `..` segments (encoded or not) before a real
/// request ever reaches a handler — that fact is a property of the HTTP
/// stack, not of this code, so it is not trusted alone:
///
/// 1. Segment-level rejection: any `.`, `..` or empty segment refuses the
///    whole request. Defense in depth against a future caller that feeds
///    this function segments from somewhere other than [Uri.pathSegments].
/// 2. Canonical-path prefix check: the lexically-joined path is resolved
///    (symlinks followed) and must land inside [webRoot]'s OWN resolved
///    path. This is what defeats the genuine reachable attack once lexical
///    `..` is off the table — a symlink planted inside web-root pointing
///    outside it.
library;

import 'dart:io';

/// Resolves [segments] (already percent-decoded, e.g. from
/// `request.uri.pathSegments`) against [webRoot]. Returns the [File] when it
/// exists and canonically resolves inside [webRoot]; null otherwise — never
/// throws, so callers can treat null as "not servable" uniformly.
File? resolveStaticFile(Directory webRoot, List<String> segments) {
  if (segments.any((s) => s.isEmpty || s == '.' || s == '..')) return null;

  final joined = segments.fold<String>(
      webRoot.path, (acc, s) => '$acc${Platform.pathSeparator}$s');
  final target = File(joined);
  if (!target.existsSync()) return null;

  final String canonicalRoot;
  final String canonicalTarget;
  try {
    canonicalRoot = webRoot.resolveSymbolicLinksSync();
    canonicalTarget = target.resolveSymbolicLinksSync();
  } on FileSystemException {
    return null;
  }
  final withinRoot = canonicalTarget == canonicalRoot ||
      canonicalTarget
          .startsWith('$canonicalRoot${Platform.pathSeparator}');
  if (!withinRoot) return null;

  return target;
}
