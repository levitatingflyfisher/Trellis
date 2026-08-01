import 'package:jobs_core/jobs_core.dart';
import 'package:test/test.dart';

import 'helpers/fakes.dart';

/// Honest ETA through the runner: progress fires after every committed unit
/// with a moving-average estimate. Monotone-sane means: with steady units
/// the estimate only shrinks, it never goes negative, and it lands on
/// exactly 0 at the finish line.
void main() {
  Future<List<JobProgress>> runAndCollect(ChainedTask task,
      {FakeClock? clock}) async {
    clock ??= FakeClock();
    final events = <JobProgress>[];
    final runner = JobRunner(
      store: InMemoryJobStore(),
      now: clock.now,
      sleep: SleepRecorder().call,
      onProgress: events.add,
    );
    await runner.run(jobId: 'ep', kind: 'transcribe', task: task);
    return events;
  }

  test('progress fires once per committed unit with running totals', () async {
    final clock = FakeClock();
    final events = await runAndCollect(ChainedTask(clock), clock: clock);
    expect(events.map((e) => e.doneUnits).toList(), [1, 2, 3, 4, 5, 6, 7]);
    expect(events.every((e) => e.totalUnits == 7), isTrue);
  });

  test('steady units → strictly decreasing etaMs, ending at exactly 0',
      () async {
    final clock = FakeClock();
    final events =
        await runAndCollect(ChainedTask(clock, unitCostMs: 100), clock: clock);
    final etas = events.map((e) => e.etaMs).toList();
    expect(etas, [600, 500, 400, 300, 200, 100, 0]);
  });

  test('etaMs is never negative, whatever the durations do', () async {
    final clock = FakeClock();
    // Wildly uneven units:
    final task = _UnevenTask(clock, costs: [10, 5000, 20, 1, 900, 300, 40]);
    final events = await runAndCollect(task, clock: clock);
    expect(events.length, 7);
    for (final e in events) {
      expect(e.etaMs, isNotNull);
      expect(e.etaMs!, greaterThanOrEqualTo(0));
    }
    expect(events.last.etaMs, 0);
  });

  test('a slow stretch RAISES the estimate mid-run — no comforting lies',
      () async {
    final clock = FakeClock();
    // Fast start, then the phone throttles:
    final task =
        _UnevenTask(clock, costs: [100, 100, 100, 2000, 2000, 2000, 2000]);
    final events = await runAndCollect(task, clock: clock);
    final etas = events.map((e) => e.etaMs!).toList();
    // After unit 3 (first slow one) the estimate must exceed the estimate
    // after unit 2, even though fewer units remain.
    expect(etas[3], greaterThan(etas[2]));
  });

  test('retry time counts: the user waits through retries too', () async {
    final clock = FakeClock();
    // Every unit costs 100ms per attempt; unit 0 takes 3 attempts.
    final task = ChainedTask(clock, unitCostMs: 100, failures: {0: 2});
    final events = await runAndCollect(task, clock: clock);
    // First measured duration is 300ms (three attempts), so the first
    // estimate reflects the world as it is: 6 × 300.
    expect(events.first.etaMs, 1800);
  });
}

/// A ChainedTask whose units cost different amounts of fake time.
class _UnevenTask extends ChainedTask {
  final List<int> costs;
  _UnevenTask(super.clock, {required this.costs}) : super(unitCostMs: 0);

  @override
  Future<void> runUnit(int unit) async {
    clock.advance(costs[unit]);
    return super.runUnit(unit);
  }
}
