import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:trellis/features/models/format.dart';
import 'package:trellis/features/models/models_screen.dart';

import '../support/fake_services.dart';

/// "On this device": every registry model with its exact size and honest
/// state; download behind the ONE consent chokepoint; pause keeps the
/// partial; delete frees the space.
void main() {
  Future<FakeModelStore> pump(WidgetTester tester,
      {FakeModelStore? store}) async {
    // A tall surface so the whole model list (5 starter entries as of
    // ADR-0006's voice) lays out without scroll churn — a plain
    // ListView still virtualizes its Elements by viewport, so a tile
    // scrolled out of the default test window's cacheExtent is genuinely
    // absent from the tree, not merely off-screen (storage_panel_test.dart's
    // established fix for the same screen).
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final s = store ?? FakeModelStore();
    await tester.pumpWidget(MaterialApp(
        home: ModelsScreen(store: s, registry: ModelRegistry.starter())));
    await tester.pumpAndSettle();
    return s;
  }

  testWidgets('lists every registry model with size and downloaded state',
      (tester) async {
    final registry = ModelRegistry.starter();
    await pump(tester,
        store: FakeModelStore(downloadedIds: {'whisper-tiny-ggml'}));

    for (final spec in registry.specs) {
      expect(find.text(modelLabel(spec.id)), findsOneWidget);
      expect(find.textContaining(formatBytes(spec.sizeBytes)),
          findsWidgets);
    }
    expect(find.text('On this device'), findsWidgets); // title + state line
    expect(
        tester
            .widgetList(find.byType(Text))
            .map((w) => (w as Text).data)
            .where((t) => t == 'Not downloaded'),
        hasLength(4),
        reason: 'four of the five starter models are absent');
  });

  testWidgets('downloading passes the consent chokepoint first',
      (tester) async {
    final store = await pump(tester);
    await tester.tap(find.byKey(const Key('model-download-silero-vad')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('consent-dialog')), findsOneWidget);
    expect(find.textContaining('2.3 MB'), findsWidgets);
    expect(find.textContaining('metered'), findsOneWidget);
    expect(store.downloadsStarted, isEmpty);

    await tester.tap(find.byKey(const Key('consent-accept')));
    await tester.pumpAndSettle();

    expect(store.downloadsStarted, ['silero-vad']);
    expect(store.downloadedIds, contains('silero-vad'));
    expect(find.byKey(const Key('model-delete-silero-vad')), findsOneWidget);
  });

  testWidgets('"Not now" downloads nothing', (tester) async {
    final store = await pump(tester);
    await tester.tap(find.byKey(const Key('model-download-silero-vad')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('consent-cancel')));
    await tester.pumpAndSettle();

    expect(store.downloadsStarted, isEmpty);
    expect(find.byKey(const Key('model-download-silero-vad')),
        findsOneWidget);
  });

  testWidgets('progress shows honest bytes and ETA; pause keeps the partial',
      (tester) async {
    final store = await pump(tester, store: FakeModelStore(beats: 5));
    await tester.tap(find.byKey(const Key('model-download-silero-vad')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('consent-accept')));

    await tester.pump(const Duration(milliseconds: 250)); // two beats
    expect(find.byKey(const Key('model-progress-silero-vad')),
        findsOneWidget);
    expect(find.textContaining('of 2.3 MB'), findsOneWidget);
    expect(find.textContaining('left'), findsOneWidget, reason: 'honest ETA');

    await tester.tap(find.byKey(const Key('model-cancel-silero-vad')));
    await tester.pumpAndSettle();

    expect(store.downloadedIds, isNot(contains('silero-vad')));
    expect(store.partial['silero-vad'], greaterThan(0));
    expect(find.textContaining('Paused'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget,
        reason: 'the kept partial is offered for resume');
  });

  testWidgets('delete asks, then removes', (tester) async {
    final store = await pump(tester,
        store: FakeModelStore(downloadedIds: {'whisper-tiny-ggml'}));
    await tester
        .tap(find.byKey(const Key('model-delete-whisper-tiny-ggml')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('delete-model-dialog')), findsOneWidget);

    await tester.tap(find.byKey(const Key('delete-model-confirm')));
    await tester.pumpAndSettle();

    expect(store.downloadedIds, isEmpty);
    expect(find.byKey(const Key('model-download-whisper-tiny-ggml')),
        findsOneWidget);
  });
}
