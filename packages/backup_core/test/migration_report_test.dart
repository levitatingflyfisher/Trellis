import 'package:backup_core/backup_core.dart';
import 'package:test/test.dart';

void main() {
  group('MigrationReport', () {
    test('is a value the UI can hold calmly: unmodifiable views, '
        'defensively copied from the caller', () {
      final imported = {'works': 2};
      final skipped = {'duplicate book (kept the newer copy)': 1};
      final dropped = ['Consents never travel.'];
      final report = MigrationReport(
        imported: imported,
        skipped: skipped,
        dropped: dropped,
      );

      // Later caller-side mutation cannot rewrite an already-shown report.
      imported['works'] = 99;
      dropped.clear();
      expect(report.imported, {'works': 2});
      expect(report.dropped, ['Consents never travel.']);

      expect(() => report.imported['x'] = 1, throwsUnsupportedError);
      expect(() => report.skipped.clear(), throwsUnsupportedError);
      expect(() => report.dropped.add('y'), throwsUnsupportedError);
    });

    test('empty migrations are representable without special cases', () {
      final report =
          MigrationReport(imported: {}, skipped: {}, dropped: []);
      expect(report.imported, isEmpty);
      expect(report.skipped, isEmpty);
      expect(report.dropped, isEmpty);
    });
  });
}
