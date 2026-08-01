import 'package:jobs_core/jobs_core.dart';
import 'package:test/test.dart';

/// The JobStore seam. The law under test: saveCheckpoint(jobId, checkpoint,
/// doneUnits) is ATOMIC — checkpoint and doneUnits land together or not at
/// all, and never invent a row. The real adapter honors this with one Drift
/// transaction; the in-memory impl is the reference semantics.
void main() {
  Job freshJob() => const Job(
        id: 'ep-42',
        kind: 'transcribe',
        state: JobState.running,
        checkpoint: null,
        totalUnits: 7,
        doneUnits: 0,
        createdAtMs: 1722700000000,
      );

  group('InMemoryJobStore', () {
    test('load of an unknown id is null', () async {
      final store = InMemoryJobStore();
      expect(await store.load('nope'), isNull);
    });

    test('save then load round-trips every field', () async {
      final store = InMemoryJobStore();
      await store.save(freshJob());
      final row = (await store.load('ep-42'))!;
      expect(row.id, 'ep-42');
      expect(row.kind, 'transcribe');
      expect(row.state, JobState.running);
      expect(row.checkpoint, isNull);
      expect(row.totalUnits, 7);
      expect(row.doneUnits, 0);
      expect(row.createdAtMs, 1722700000000);
    });

    test('save upserts — the second save wins whole-row', () async {
      final store = InMemoryJobStore();
      await store.save(freshJob());
      await store.save(freshJob().copyWith(state: JobState.cancelled, doneUnits: 3));
      final row = (await store.load('ep-42'))!;
      expect(row.state, JobState.cancelled);
      expect(row.doneUnits, 3);
    });

    test('saveCheckpoint commits checkpoint and doneUnits together, touching nothing else', () async {
      final store = InMemoryJobStore();
      await store.save(freshJob());
      await store.saveCheckpoint('ep-42', 'windows:0-3', 3);
      final row = (await store.load('ep-42'))!;
      expect(row.checkpoint, 'windows:0-3');
      expect(row.doneUnits, 3);
      // The rest of the row is untouched:
      expect(row.state, JobState.running);
      expect(row.kind, 'transcribe');
      expect(row.totalUnits, 7);
      expect(row.createdAtMs, 1722700000000);
    });

    test('saveCheckpoint for an unknown job throws and writes NOTHING', () async {
      final store = InMemoryJobStore();
      await expectLater(
        store.saveCheckpoint('ghost', 'cp', 1),
        throwsStateError,
      );
      expect(await store.load('ghost'), isNull);
    });

    test('delete removes the row, checkpoint and all', () async {
      final store = InMemoryJobStore();
      await store.save(freshJob().copyWith(checkpoint: 'cp', doneUnits: 2));
      await store.delete('ep-42');
      expect(await store.load('ep-42'), isNull);
    });

    test('delete of an unknown id is a quiet no-op', () async {
      final store = InMemoryJobStore();
      await store.delete('never-existed'); // must not throw
    });
  });

  group('Job.copyWith', () {
    test('keeps every unnamed field', () {
      final row = freshJob().copyWith(doneUnits: 5);
      expect(row.id, 'ep-42');
      expect(row.kind, 'transcribe');
      expect(row.state, JobState.running);
      expect(row.checkpoint, isNull);
      expect(row.totalUnits, 7);
      expect(row.createdAtMs, 1722700000000);
      expect(row.doneUnits, 5);
    });
  });
}
