import 'package:flutter_test/flutter_test.dart';

/// Picks [name] on 'Who’s reading?' when the app is showing it. A cold
/// launch opens straight into the only (or the last) reader's Library, so
/// the picker appears only when there is a real choice; tests that seed
/// one reader and those that seed several share this one step.
Future<void> pickReader(WidgetTester tester, String name) async {
  if (find.text('Who’s reading?').evaluate().isEmpty) return;
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
}
