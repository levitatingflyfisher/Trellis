import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/models/format.dart';

void main() {
  group('formatBytes', () {
    test('honest units at each magnitude', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(999), '999 B');
      expect(formatBytes(43537433), '43.5 MB');
      expect(formatBytes(2327524), '2.3 MB');
      expect(formatBytes(546660344), '546.7 MB');
      expect(formatBytes(81768585), '81.8 MB');
      expect(formatBytes(1536), '1.5 kB');
      expect(formatBytes(1200000000), '1.2 GB');
    });
  });

  group('formatEta', () {
    test('speaks in calm approximations, never a stopwatch', () {
      expect(formatEta(null), '');
      expect(formatEta(20000), 'under a minute left');
      expect(formatEta(90000), 'about 2 min left');
      expect(formatEta(60000 * 59), 'about 59 min left');
      expect(formatEta(3600000 * 2 + 60000), 'about 2 h left');
    });
  });
}
