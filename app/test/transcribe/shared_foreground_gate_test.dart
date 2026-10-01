import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/transcribe/foreground_gate.dart';

import '../support/fake_services.dart';

/// One screen-off service, many jobs: the notification stays up until the
/// LAST running job finishes, never the first.
void main() {
  test('the service stops only when the last job finishes', () async {
    final inner = RecordingForegroundGate();
    final gate = SharedJobForegroundGate(inner);

    await gate.jobStarted('Episode A', 'Downloading…');
    await gate.jobStarted('Episode B', 'Transcribing…');
    await gate.jobFinished();
    expect(inner.events, isNot(contains('finished')));

    await gate.jobFinished();
    expect(inner.events.last, 'finished');
  });

  test('a stray extra finish never drives the count below zero', () async {
    final inner = RecordingForegroundGate();
    final gate = SharedJobForegroundGate(inner);

    await gate.jobFinished();
    await gate.jobStarted('Episode A', 'Downloading…');
    expect(inner.events, ['start:Episode A']);
  });

  test('a start the platform refused holds no count', () async {
    final inner = ThrowingStartGate();
    final gate = SharedJobForegroundGate(inner);

    await expectLater(gate.jobStarted('A', 'x'), throwsStateError);
    await expectLater(gate.jobStarted('B', 'x'), throwsStateError);

    expect(inner.events, ['start-failed:A', 'start-failed:B'],
        reason: 'the second start must try the service again, not treat '
            'it as already running');
  });
}
