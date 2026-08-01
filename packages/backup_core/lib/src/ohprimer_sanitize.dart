import 'dart:typed_data';

/// The donor ohPrimer's import sanitization, ported (index.html
/// `sanitizeImported`, H4): strip prototype-polluting keys from untrusted
/// parsed JSON before it touches storage. Recursive and depth-capped exactly
/// like the donor (past depth 30 the value is returned unchanged — parity,
/// pinned by test).
///
/// Dart maps are not prototype-vulnerable the way JS objects are, but the
/// law is about what gets *persisted*: a key named `__proto__` written today
/// is a landmine for any future JS surface (the PWA) that reads the rows.
/// Typed-data values pass through untouched, mirroring the donor's
/// Blob/ArrayBuffer carve-out.
Object? sanitizePrimerValue(Object? value, [int depth = 0]) {
  if (depth > 30 || value == null) return value;
  if (value is TypedData || value is ByteBuffer) return value;
  if (value is List) {
    return [for (final item in value) sanitizePrimerValue(item, depth + 1)];
  }
  if (value is Map) {
    final out = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) continue; // decoded JSON keys are always strings
      if (key == '__proto__' || key == 'constructor' || key == 'prototype') {
        continue;
      }
      out[key] = sanitizePrimerValue(entry.value, depth + 1);
    }
    return out;
  }
  return value;
}
