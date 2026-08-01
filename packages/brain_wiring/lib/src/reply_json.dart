/// Pulling the one JSON object out of a model reply.
///
/// Models wrap JSON in prose and ``` fences no matter how firmly asked
/// not to; the robust move is to take the outermost brace span and let
/// the strict parser judge what is inside.
library;

/// Returns the substring from the first `{` to the last `}` of [reply].
///
/// Throws a [FormatException] when no object-shaped span exists — the
/// caller treats that exactly like any other parse failure (repair round
/// or typed failure).
String extractJsonObject(String reply) {
  final start = reply.indexOf('{');
  final end = reply.lastIndexOf('}');
  if (start == -1 || end <= start) {
    throw const FormatException(
        'reply contained no JSON object (expected {...})');
  }
  return reply.substring(start, end + 1);
}
