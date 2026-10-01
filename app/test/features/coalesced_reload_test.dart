import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/shared/coalesced_reload.dart';

void main() {
  test('a burst of requests during one reload costs one more reload, not '
      'one each', () async {
    var runs = 0;
    final gate = Completer<void>();
    final reload = CoalescedReload(() async {
      runs++;
      if (runs == 1) await gate.future;
    });

    final first = reload.request();
    // An OPML import beats progress once per feed: a hundred beats land
    // while the first reload is still reading.
    final rest = [for (var i = 0; i < 100; i++) reload.request()];
    gate.complete();
    await Future.wait([first, ...rest]);

    expect(runs, 2);
  });

  test('every caller sees a reload that started after its request', () async {
    final seen = <int>[];
    var value = 0;
    final gate = Completer<void>();
    final reload = CoalescedReload(() async {
      final snapshot = value;
      if (seen.isEmpty) await gate.future;
      seen.add(snapshot);
    });

    final first = reload.request();
    value = 1;
    final second = reload.request();
    gate.complete();
    await Future.wait([first, second]);

    expect(seen, [0, 1]);
  });

  test('requests after a reload finished run it again', () async {
    var runs = 0;
    final reload = CoalescedReload(() async => runs++);
    await reload.request();
    await reload.request();
    expect(runs, 2);
  });
}
