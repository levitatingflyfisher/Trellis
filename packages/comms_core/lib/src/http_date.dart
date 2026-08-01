/// HTTP-date helpers and the JS parseInt shim. The donor used
/// `Date.prototype.toUTCString` (OPML dateCreated), `Date.parse` and
/// `parseInt` (Retry-After); pure Dart has none of the three.
library;

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _two(int n) => n.toString().padLeft(2, '0');

/// RFC 1123 / `toUTCString` shape: `Wed, 05 Aug 2026 12:00:00 GMT`.
String formatHttpDate(DateTime d) {
  final u = d.toUtc();
  return '${_weekdays[u.weekday - 1]}, ${_two(u.day)} ${_months[u.month - 1]} '
      '${u.year} ${_two(u.hour)}:${_two(u.minute)}:${_two(u.second)} GMT';
}

final _rfc1123 = RegExp(
    r'^[A-Za-z]{3},\s+(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+'
    r'(\d{2}):(\d{2}):(\d{2})\s+GMT$');

/// Parses RFC 1123, falling back to [DateTime.tryParse] (ISO-8601 etc.) —
/// an approximation of the donor's lenient `Date.parse`. Returns null on
/// garbage.
DateTime? parseHttpDate(String s) {
  final t = s.trim();
  if (t.isEmpty) return null;
  final m = _rfc1123.firstMatch(t);
  if (m != null) {
    final month = _months.indexOf(m.group(2)!);
    if (month < 0) return null;
    return DateTime.utc(
      int.parse(m.group(3)!),
      month + 1,
      int.parse(m.group(1)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6)!),
    );
  }
  return DateTime.tryParse(t);
}

final _intPrefix = RegExp(r'^\s*([+-]?\d+)');

/// JS `parseInt(s, 10)`: leading whitespace and sign, then as many digits
/// as it can, ignoring the rest. Null when no digits lead (JS NaN).
int? parseIntPrefix(String s) {
  final m = _intPrefix.firstMatch(s);
  return m == null ? null : int.parse(m.group(1)!);
}
