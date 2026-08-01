import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/bootstrap/boot_guard.dart';

/// 1.4.0's lesson, made checkable: everything `main()` awaits before
/// `runApp()` is load-bearing for the *whole app*, not just for its own
/// feature. A plugin that throws there does not degrade that plugin — it
/// stops the first frame ever being painted, and Android goes on showing
/// the launch logo with nothing to say why.
///
/// [bestEffort] is the rule that a boot step may fail loudly in the logs
/// and visibly in the UI, but may never take the boot with it.
void main() {
  group('bestEffort', () {
    test('returns the step result and records nothing when it succeeds',
        () async {
      final notes = <String>[];
      final value = await bestEffort<int>(
        what: 'Counting',
        run: () async => 42,
        orElse: () => -1,
        notes: notes,
      );
      expect(value, 42);
      expect(notes, isEmpty);
    });

    test('falls back and records a note when the step throws', () async {
      final notes = <String>[];
      final value = await bestEffort<int>(
        what: 'Lock-screen controls',
        run: () async => throw StateError('wrong FlutterEngine'),
        orElse: () => -1,
        notes: notes,
      );
      expect(value, -1, reason: 'the fallback must be used, not a rethrow');
      expect(notes, hasLength(1));
      expect(notes.single, contains('Lock-screen controls'));
      expect(notes.single, contains('wrong FlutterEngine'),
          reason: 'the note must carry the real cause, not a generic string');
    });

    test('a synchronous throw inside the step is caught too', () async {
      // `JustAudioBackground.init()` reaches a platform channel before its
      // first await; a try/catch that only covers the async part would miss
      // exactly the failure that bricked 1.4.0.
      final notes = <String>[];
      final value = await bestEffort<int>(
        what: 'Storage',
        run: () => throw ArgumentError('boom'),
        orElse: () => 7,
        notes: notes,
      );
      expect(value, 7);
      expect(notes.single, contains('Storage'));
    });
  });

  group('BootNotice', () {
    Widget harness(List<String> notes) => MaterialApp(
          home: BootNotice(notes: notes, child: const Text('the app')),
        );

    testWidgets('shows nothing when the boot was clean', (tester) async {
      await tester.pumpWidget(harness(const []));
      expect(find.text('the app'), findsOneWidget);
      expect(find.byType(MaterialBanner), findsNothing);
    });

    testWidgets('surfaces each note, and the app still renders',
        (tester) async {
      await tester.pumpWidget(
          harness(const ['Lock-screen controls unavailable: boom']));
      // The app is reachable — a degraded boot is still a boot.
      expect(find.text('the app'), findsOneWidget);
      expect(find.byType(MaterialBanner), findsOneWidget);
      expect(find.textContaining('Lock-screen controls'), findsOneWidget);
    });

    testWidgets('the notice can be dismissed', (tester) async {
      await tester
          .pumpWidget(harness(const ['Lock-screen controls unavailable: x']));
      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      expect(find.byType(MaterialBanner), findsNothing);
      expect(find.text('the app'), findsOneWidget);
    });
  });
}
