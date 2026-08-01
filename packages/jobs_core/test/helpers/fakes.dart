/// Test doubles for the job engine.
library;

import 'package:jobs_core/jobs_core.dart';

/// Deterministic ms clock. Tasks advance it to simulate work.
class FakeClock {
  int nowMs;
  FakeClock([this.nowMs = 1722700000000]);
  int now() => nowMs;
  void advance(int ms) {
    nowMs += ms;
  }
}

/// A sleep seam that never touches a timer — records what the runner asked
/// for and returns immediately.
class SleepRecorder {
  final List<int> slept = [];
  Future<void> call(int ms) async {
    slept.add(ms);
  }
}

/// Thrown by [KillingStore] to simulate the process dying. In real life
/// nothing is thrown — the process is simply gone — but from the store's
/// point of view the two are identical: writes stop mid-stream.
class KilledProcess implements Exception {
  @override
  String toString() => 'KilledProcess (simulated kill)';
}

/// Wraps a real store and kills the process at the Nth checkpoint commit.
///
/// Two flavors, covering both halves of every unit boundary:
///  - [commitLands] true: the commit is written, THEN the process dies
///    (kill after the transaction).
///  - [commitLands] false: the process dies before the write applies
///    (kill during/before the transaction — the unit ran but its commit
///    is lost, so resume must re-run it).
class KillingStore implements JobStore {
  final JobStore inner;
  final int killOnCommit; // 1-based saveCheckpoint call number
  final bool commitLands;
  int _commits = 0;

  KillingStore(this.inner,
      {required this.killOnCommit, required this.commitLands});

  @override
  Future<Job?> load(String jobId) => inner.load(jobId);

  @override
  Future<void> save(Job job) => inner.save(job);

  @override
  Future<void> saveCheckpoint(
      String jobId, String checkpoint, int doneUnits) async {
    _commits++;
    if (_commits == killOnCommit) {
      if (commitLands) {
        await inner.saveCheckpoint(jobId, checkpoint, doneUnits);
      }
      throw KilledProcess();
    }
    await inner.saveCheckpoint(jobId, checkpoint, doneUnits);
  }

  @override
  Future<void> delete(String jobId) => inner.delete(jobId);
}

int fnv32(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

/// A 7-unit task whose output is a HASH CHAIN: each unit appends a token
/// derived from everything before it. Any resume mistake — a skipped unit,
/// a re-run of a committed unit, state not carried by the checkpoint —
/// changes the final bytes. Output depends only on restored state, never
/// on the clock or on instance memory that a kill would erase.
class ChainedTask implements ChunkedTask {
  @override
  final int totalUnits;
  final FakeClock clock;
  final int unitCostMs;

  /// unit index → how many times it throws before succeeding.
  final Map<int, int> _failuresLeft;

  /// Fires after a unit SUCCEEDS (before its commit) — how tests cancel
  /// mid-run.
  final void Function(int unit)? afterUnit;

  String _output = '';
  final List<int> unitsRun = [];
  bool restoreCalled = false;

  ChainedTask(
    this.clock, {
    this.totalUnits = 7,
    this.unitCostMs = 100,
    Map<int, int> failures = const {},
    this.afterUnit,
  }) : _failuresLeft = Map.of(failures);

  String get output => _output;

  @override
  Future<void> runUnit(int unit) async {
    unitsRun.add(unit);
    clock.advance(unitCostMs);
    final left = _failuresLeft[unit] ?? 0;
    if (left > 0) {
      _failuresLeft[unit] = left - 1;
      throw StateError('unit $unit flaked');
    }
    _output = '$_output[u$unit:${fnv32(_output).toRadixString(16)}]';
    afterUnit?.call(unit);
  }

  @override
  String checkpoint() => _output;

  @override
  void restore(String checkpoint) {
    restoreCalled = true;
    _output = checkpoint;
  }
}
