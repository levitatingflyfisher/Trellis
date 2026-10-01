import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A row's tap opens the work page (1.5.4); its Read opens the reader.
/// For the tests whose subject is the reader, not how it was reached.
Future<void> openToRead(WidgetTester tester, String title) async {
  await tester.tap(find.text(title));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('mode-read')));
  await tester.pumpAndSettle();
}
