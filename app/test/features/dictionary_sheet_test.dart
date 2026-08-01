import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/reader/dictionary_sheet.dart';

/// Campaign 4 Phase 3: the tap-hold definition sheet — calm, dismissible,
/// and the ONE place a long-pressed word's "keep to the word ledger"
/// action lives now (handoff #4: it absorbs the gesture rather than
/// stacking a second long-press on top of the existing one).
void main() {
  Future<void> open(
    WidgetTester tester, {
    required Future<String?> Function(String) lookupDefinition,
    required Future<void> Function() onKeep,
    String word = 'hello',
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => showDefinitionSheet(context,
              word: word, lookupDefinition: lookupDefinition, onKeep: onKeep),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the word while the lookup is pending, then the '
      'definition once it resolves', (tester) async {
    // A Completer the test controls directly — pumpAndSettle would run the
    // future to completion before any assertion runs, so the pending
    // branch (the spinner) would never actually be observed. Hold it open
    // on purpose.
    final pending = Completer<String?>();
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => showDefinitionSheet(context,
              word: 'hello',
              lookupDefinition: (w) => pending.future,
              onKeep: () async {}),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump(); // build the sheet
    await tester.pump(); // let showModalBottomSheet's route settle in

    expect(find.text('hello'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('a greeting'), findsNothing);

    pending.complete('a greeting');
    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('a greeting'), findsOneWidget);
  });

  testWidgets('no definition available shows one calm, honest empty state',
      (tester) async {
    await open(tester, lookupDefinition: (w) async => null, onKeep: () async {});
    expect(find.textContaining('No definition'), findsOneWidget);
  });

  testWidgets('the keep button calls onKeep and closes the sheet — one '
      'tap, same speed as the long-press-to-keep gesture it replaces',
      (tester) async {
    var kept = false;
    await open(tester,
        lookupDefinition: (w) async => 'a greeting',
        onKeep: () async => kept = true);

    await tester.tap(find.byKey(const Key('definition-sheet-keep')));
    await tester.pumpAndSettle();
    expect(kept, isTrue);
    expect(find.byKey(const Key('dictionary-sheet')), findsNothing);
  });

  testWidgets('a close button dismisses the sheet', (tester) async {
    await open(tester,
        lookupDefinition: (w) async => 'a greeting', onKeep: () async {});
    expect(find.byKey(const Key('dictionary-sheet')), findsOneWidget);

    await tester.tap(find.byKey(const Key('definition-sheet-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dictionary-sheet')), findsNothing);
  });
}
