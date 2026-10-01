import 'package:drift/drift.dart';

/// Counts the database round trips a test makes; a drift batch is one.
class StatementCounter extends QueryInterceptor {
  final calls = <String>[];

  static final _write =
      RegExp(r'(?:INSERT(?: OR \w+)? INTO|UPDATE|DELETE FROM) "?(\w+)"?');

  /// How many round trips wrote each table.
  Map<String, int> writesPerTable() {
    final out = <String, int>{};
    for (final sql in calls) {
      for (final t in {for (final m in _write.allMatches(sql)) m.group(1)!}) {
        out[t] = (out[t] ?? 0) + 1;
      }
    }
    return out;
  }

  @override
  Future<int> runInsert(QueryExecutor e, String s, List<Object?> a) {
    calls.add(s);
    return super.runInsert(e, s, a);
  }

  @override
  Future<int> runUpdate(QueryExecutor e, String s, List<Object?> a) {
    calls.add(s);
    return super.runUpdate(e, s, a);
  }

  @override
  Future<int> runDelete(QueryExecutor e, String s, List<Object?> a) {
    calls.add(s);
    return super.runDelete(e, s, a);
  }

  @override
  Future<void> runCustom(QueryExecutor e, String s, List<Object?> a) {
    calls.add(s);
    return super.runCustom(e, s, a);
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
      QueryExecutor e, String s, List<Object?> a) {
    calls.add(s);
    return super.runSelect(e, s, a);
  }

  @override
  Future<void> runBatched(QueryExecutor e, BatchedStatements statements) {
    calls.add(statements.statements.join('\n'));
    return super.runBatched(e, statements);
  }

  /// How many reads matched [pattern].
  int selectsMatching(Pattern pattern) => calls
      .where((sql) => sql.startsWith('SELECT') && sql.contains(pattern))
      .length;
}
