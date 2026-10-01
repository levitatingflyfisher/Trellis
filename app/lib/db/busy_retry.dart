/// Retrying a write that lost the lock to another connection (ADR-0018).
///
/// The background check and the app can each hold a connection to the
/// database file. The busy timeout ought to make a writer wait, but on a
/// measured host SQLite (3.50.2) two connections in one process got
/// SQLITE_BUSY back after about 30 ms, whatever the timeout said, and the
/// app and the worker engine share one process on Android. So the writes
/// that can overlap retry on their own, after drift has rolled back.
library;

import 'package:drift/remote.dart' show DriftRemoteException;

const _sqliteBusy = 5;

/// Whether [error] is SQLITE_BUSY, unwrapped from drift's isolate
/// transport. Read off `resultCode` by name: the native and web sqlite3
/// exceptions are different classes, and importing the native one would
/// pull dart:ffi into the web build.
bool isDatabaseBusy(Object error) {
  final cause = error is DriftRemoteException ? error.remoteCause : error;
  try {
    return ((cause as dynamic).resultCode as int) & 0xff == _sqliteBusy;
  } catch (_) {
    return false;
  }
}

/// Runs [write] again while it fails busy, for up to about [budget]. The
/// caller's work must be one transaction, so a failed try left nothing.
Future<T> retryWhileBusy<T>(Future<T> Function() write,
    {Duration budget = const Duration(seconds: 10)}) async {
  final sw = Stopwatch()..start();
  var delay = const Duration(milliseconds: 20);
  while (true) {
    try {
      return await write();
    } catch (e) {
      if (!isDatabaseBusy(e) || sw.elapsed + delay > budget) rethrow;
      await Future<void>.delayed(delay);
      if (delay < const Duration(milliseconds: 500)) delay *= 2;
    }
  }
}
