/// The persistence seam for job rows.
library;

import 'job.dart';

/// Where job rows live. The app implements this over Drift; tests use
/// [InMemoryJobStore].
///
/// The one law an implementation MUST honor: [saveCheckpoint] is atomic.
/// checkpoint and doneUnits commit together or not at all — in the real
/// adapter, in the SAME transaction as the unit's output rows. That single
/// property is what makes "kill the app anywhere, resume byte-identical"
/// possible.
abstract class JobStore {
  Future<Job?> load(String jobId);

  /// Whole-row upsert.
  Future<void> save(Job job);

  /// Atomically record that one more unit is fully committed. Throws
  /// [StateError] (writing nothing) if no such job exists — a checkpoint
  /// may never invent a row.
  Future<void> saveCheckpoint(String jobId, String checkpoint, int doneUnits);

  /// Abandon: forget the job, checkpoint and all. No-op if absent.
  Future<void> delete(String jobId);
}

/// Reference semantics, for tests. A map update is inherently atomic on the
/// single-threaded Dart event loop, so the atomicity law holds trivially —
/// what this impl pins is the CONTRACT (merge exactly two fields, refuse
/// unknown ids) that a Drift adapter must reproduce transactionally.
class InMemoryJobStore implements JobStore {
  final Map<String, Job> _rows = {};

  @override
  Future<Job?> load(String jobId) async => _rows[jobId];

  @override
  Future<void> save(Job job) async {
    _rows[job.id] = job;
  }

  @override
  Future<void> saveCheckpoint(
      String jobId, String checkpoint, int doneUnits) async {
    final row = _rows[jobId];
    if (row == null) {
      throw StateError('saveCheckpoint for unknown job "$jobId"');
    }
    _rows[jobId] = row.copyWith(checkpoint: checkpoint, doneUnits: doneUnits);
  }

  @override
  Future<void> delete(String jobId) async {
    _rows.remove(jobId);
  }
}
