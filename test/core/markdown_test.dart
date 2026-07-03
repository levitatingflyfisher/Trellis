import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/core/markdown.dart';

void main() {
  testWidgets('MdText does not auto-fetch remote images (no NetworkImage)',
      (tester) async {
    // Untrusted course markdown with a remote image would, by default, render
    // an Image(NetworkImage(url)) — a silent outbound GET (tracking beacon).
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: MdText('![beacon](https://example.com/x.png?u=1)'),
      ),
    ));
    // One frame only — a NetworkImage never settles, so pumpAndSettle would hang.
    await tester.pump();

    expect(
      find.byWidgetPredicate((w) => w is Image && w.image is NetworkImage),
      findsNothing,
      reason: 'a markdown image must not trigger an outbound network fetch',
    );
  });
}
