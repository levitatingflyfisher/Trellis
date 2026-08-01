/// HTTP-date formatting/parsing and the JS parseInt-prefix shim — the
/// donor leaned on `Date.prototype.toUTCString`, `Date.parse` and
/// `parseInt`; pure Dart has none of the three.
library;

import 'package:comms_core/comms_core.dart';
import 'package:test/test.dart';

void main() {
  group('formatHttpDate', () {
    test('matches toUTCString shape', () {
      expect(formatHttpDate(DateTime.utc(2026, 8, 5, 12, 0, 0)),
          'Wed, 05 Aug 2026 12:00:00 GMT');
      expect(formatHttpDate(DateTime.utc(2024, 1, 1, 3, 7, 9)),
          'Mon, 01 Jan 2024 03:07:09 GMT');
    });

    test('converts local times to UTC first', () {
      final local = DateTime.utc(2026, 8, 5, 12).toLocal();
      expect(formatHttpDate(local), 'Wed, 05 Aug 2026 12:00:00 GMT');
    });
  });

  group('parseHttpDate', () {
    test('parses RFC 1123', () {
      expect(parseHttpDate('Wed, 05 Aug 2026 12:00:00 GMT'),
          DateTime.utc(2026, 8, 5, 12, 0, 0));
    });

    test('parses ISO-8601 as a fallback (donor Date.parse accepted it)', () {
      expect(parseHttpDate('2026-08-05T12:00:00Z'),
          DateTime.utc(2026, 8, 5, 12, 0, 0));
    });

    test('rejects garbage', () {
      expect(parseHttpDate('soon'), isNull);
      expect(parseHttpDate(''), isNull);
    });
  });

  group('parseIntPrefix (JS parseInt semantics)', () {
    test('plain integers', () {
      expect(parseIntPrefix('120'), 120);
      expect(parseIntPrefix('-5'), -5);
      expect(parseIntPrefix('+7'), 7);
    });
    test('leading digits win, trailing junk ignored', () {
      expect(parseIntPrefix('120s'), 120);
      expect(parseIntPrefix('  42abc'), 42);
    });
    test('no leading digits: null (JS NaN)', () {
      expect(parseIntPrefix('abc'), isNull);
      expect(parseIntPrefix(''), isNull);
    });
  });
}
