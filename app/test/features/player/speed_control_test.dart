import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/player/mini_player_host.dart';
import 'package:trellis/features/player/speed_control.dart';

void main() {
  test('clampSpeed keeps 0.5-4.0 in twentieths, so 1.25 and 1.75 hold', () {
    expect(clampSpeed(0.2), 0.5);
    expect(clampSpeed(7), 4.0);
    expect(clampSpeed(1.26), 1.25);
    expect(clampSpeed(1.75), 1.75);
    expect(clampSpeed(1.1 + 0.2), 1.3);
  });

  test('a drag maps to one step per 24dp; up is faster', () {
    expect(speedAfterDrag(1.0, -24), 1.1);
    expect(speedAfterDrag(1.0, -47), 1.1);
    expect(speedAfterDrag(1.0, -48), 1.2);
    expect(speedAfterDrag(1.5, 24 * 5), 1.0);
    expect(speedAfterDrag(3.9, -24 * 10), 4.0);
    expect(speedAfterDrag(0.6, 24 * 10), 0.5);
  });

  test('labels drop a trailing .0', () {
    expect(speedLabel(1.0), '1×');
    expect(speedLabel(1.5), '1.5×');
    expect(speedLabel(1.25), '1.25×');
  });

  Future<List<double>> pump(WidgetTester tester, double speed) async {
    final seen = <double>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: StatefulBuilder(
            builder: (context, setState) => SpeedControl(
              key: const Key('speed'),
              speed: speed,
              onChanged: (s) => setState(() {
                speed = s;
                seen.add(s);
              }),
            ),
          ),
        ),
      ),
    ));
    return seen;
  }

  testWidgets('swiping up on the control speeds up, down slows', (tester) async {
    final seen = await pump(tester, 1.0);
    await tester.drag(find.byKey(const Key('speed')), const Offset(0, -80));
    await tester.pump();
    expect(seen.last, 1.3);
    expect(find.text('1.3×'), findsOneWidget);
    await tester.drag(find.byKey(const Key('speed')), const Offset(0, 130));
    await tester.pump();
    expect(seen.last, 0.8);
  });

  testWidgets('a tap opens a plain list of presets, the current one checked; '
      'one tap sets it', (tester) async {
    final seen = await pump(tester, 1.25);
    await tester.tap(find.byKey(const Key('speed')));
    await tester.pumpAndSettle();
    expect(speedPresets, [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0]);
    for (final p in speedPresets) {
      expect(find.byKey(Key('speed-preset-$p')), findsOneWidget);
    }
    expect(find.byKey(const Key('speed-wheel')), findsNothing);
    expect(
        find.descendant(
            of: find.byKey(const Key('speed-preset-1.25')),
            matching: find.byIcon(Icons.check)),
        findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
    await tester.tap(find.byKey(const Key('speed-preset-3.0')));
    await tester.pumpAndSettle();
    expect(seen.last, 3.0);
    expect(find.byKey(const Key('speed-preset-3.0')), findsNothing);
  });

  // 1.5.6: the mini player sits below the Navigator (MaterialApp.builder),
  // so a sheet's barrier never covers its speed button, and each tap
  // stacked another sheet.
  testWidgets('tapping the mini player\'s speed twice opens one sheet',
      (tester) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      home: const Scaffold(body: SizedBox.expand()),
      builder: (context, child) => MiniPlayerHost(
        routes: MiniPlayerRoutes(),
        navigatorKey: nav,
        child: Column(children: [
          Expanded(child: child!),
          Material(
            child: SpeedControl(
                key: const Key('bar-speed'), speed: 1.0, onChanged: (_) {}),
          ),
        ]),
      ),
    ));
    await tester.tap(find.byKey(const Key('bar-speed')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bar-speed')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('speed-sheet')), findsOneWidget);
    // Closed, it opens again.
    await tester.tap(find.byKey(const Key('speed-preset-2.0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('speed-sheet')), findsNothing);
    await tester.tap(find.byKey(const Key('bar-speed')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('speed-sheet')), findsOneWidget);
    // Closed again, so the app-wide guard doesn't leak into later tests.
    await tester.tap(find.byKey(const Key('speed-preset-1.0')));
    await tester.pumpAndSettle();
  });
}
