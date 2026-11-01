import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/services/host_activity.dart';

/// Android can start the app's engine with no screen: media resumption
/// after a boot starts the audio service alone. The activity's own
/// channels are not attached then, and a call into them throws
/// MissingPluginException. Such a call waits for the app to open.
void main() {
  test('a call that finds the activity attached runs once, at once',
      () async {
    var calls = 0;
    final got = await onceHostAttached(() async => ++calls,
        resumed: () => Completer<void>().future);
    expect(got, 1);
    expect(calls, 1);
  });

  test('with no activity, the call waits for the app to open, then runs '
      'again, without an error', () async {
    var attached = false;
    var calls = 0;
    final opened = StreamController<void>.broadcast();
    final result = onceHostAttached(() async {
      calls++;
      if (!attached) throw MissingPluginException('no activity');
      return 'taken';
    }, resumed: () => opened.stream.first);
    String? got;
    unawaited(result.then((v) => got = v));
    await pumpEventQueue();
    expect(calls, 1);
    expect(got, isNull, reason: 'nothing runs until the app opens');

    attached = true;
    opened.add(null);
    await pumpEventQueue();
    expect(got, 'taken');
    expect(calls, 2);
  });

  test('any other failure is not swallowed', () async {
    expect(
        onceHostAttached<void>(() async => throw StateError('real'),
            resumed: () async {}),
        throwsStateError);
  });

  testWidgets('appResumed completes when the app comes to the front',
      (tester) async {
    var done = false;
    unawaited(appResumed().then((_) => done = true));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(done, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(done, isTrue);
  });
}
