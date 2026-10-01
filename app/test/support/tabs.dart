import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A bottom tab's label. Latest and Queue also title their own screens,
/// so a bare `find.text` can match the app bar as well as the tab.
Finder tabLabel(String label) => find.descendant(
    of: find.byType(NavigationBar), matching: find.text(label));

/// Switches to the [label] tab. The app opens on Latest, so a test about
/// the Library or Courses goes there first.
Future<void> toTab(WidgetTester tester, String label) async {
  await tester.tap(tabLabel(label));
  await tester.pumpAndSettle();
}
