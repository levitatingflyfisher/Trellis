import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;
import 'package:trellis/db/busy_retry.dart';

void main() {
  test('SQLITE_BUSY and its extended codes count as busy; other errors '
      'do not', () {
    expect(isDatabaseBusy(SqliteException(5, 'database is locked')), isTrue);
    expect(isDatabaseBusy(SqliteException(517, 'busy snapshot')), isTrue);
    expect(isDatabaseBusy(SqliteException(19, 'constraint')), isFalse);
    expect(isDatabaseBusy(StateError('no')), isFalse);
  });

  test('a busy write runs again; anything else is thrown at once', () async {
    var tries = 0;
    final v = await retryWhileBusy(() async {
      if (++tries < 3) throw SqliteException(5, 'database is locked');
      return 'done';
    });
    expect((v, tries), ('done', 3));

    tries = 0;
    await expectLater(
        retryWhileBusy(() async {
          tries++;
          throw SqliteException(19, 'constraint');
        }),
        throwsA(isA<SqliteException>()));
    expect(tries, 1);
  });

  test('it gives up once the budget is spent', () async {
    await expectLater(
        retryWhileBusy(() async => throw SqliteException(5, 'locked'),
            budget: const Duration(milliseconds: 100)),
        throwsA(isA<SqliteException>()));
  });
}
