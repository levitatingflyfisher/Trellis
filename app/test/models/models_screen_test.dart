import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:trellis/features/models/format.dart';
import 'package:trellis/features/models/models_screen.dart';

import '../support/fake_services.dart';

/// "Models & storage": every registry model with its exact size and honest
/// state; download behind the ONE consent chokepoint; pause keeps the
/// partial; delete frees the space.
void main() {
  Future<FakeModelStore> pump(
    WidgetTester tester, {
    FakeModelStore? store,
  }) async {
    // A tall surface so the whole model list (13 starter entries as of
    // Campaign 8's six new Babel pairs, up from 7 after Campaign 4's
    // dictionary) lays out without scroll churn — a plain ListView still
    // virtualizes its Elements by viewport, so a tile scrolled out of
    // the default test window's cacheExtent is genuinely absent from the
    // tree, not merely off-screen (storage_panel_test.dart's established
    // fix for the same screen).
    tester.view.physicalSize = const Size(800, 5600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final s = store ?? FakeModelStore();
    await tester.pumpWidget(
      MaterialApp(
        home: ModelsScreen(store: s, registry: ModelRegistry.starter()),
      ),
    );
    await tester.pumpAndSettle();
    return s;
  }

  testWidgets('lists every registry model with size and downloaded state', (
    tester,
  ) async {
    final registry = ModelRegistry.starter();
    await pump(
      tester,
      store: FakeModelStore(downloadedIds: {'whisper-tiny-ggml'}),
    );

    final listed = [
      for (final s in registry.specs)
        if (s.task != ModelTask.translation) s,
    ];
    for (final spec in listed) {
      expect(find.text(modelLabel(spec.id)), findsOneWidget);
      expect(find.textContaining(formatBytes(spec.sizeBytes)), findsWidgets);
    }
    expect(find.text('Models & storage'), findsOneWidget); // the title
    expect(find.text('On this device'), findsOneWidget); // a state line
    expect(
      tester
          .widgetList(find.byType(Text))
          .map((w) => (w as Text).data)
          .where((t) => t == 'Not downloaded'),
      hasLength(listed.length - 1),
      reason: 'every starter model but the one downloaded id is absent — '
          'derived from the registry itself (Campaign 8 "Babel widens" '
          'added six more entries) rather than a count that goes stale '
          'every time the starter catalog grows',
    );
  });

  testWidgets('downloading passes the consent chokepoint first', (
    tester,
  ) async {
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
    expect(find.byKey(const Key('model-download-silero-vad')), findsOneWidget);
  });

  testWidgets('progress shows honest bytes and ETA; pause keeps the partial', (
    tester,
  ) async {
    final store = await pump(tester, store: FakeModelStore(beats: 5));
    await tester.tap(find.byKey(const Key('model-download-silero-vad')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('consent-accept')));

    await tester.pump(const Duration(milliseconds: 250)); // two beats
    expect(find.byKey(const Key('model-progress-silero-vad')), findsOneWidget);
    expect(find.textContaining('of 2.3 MB'), findsOneWidget);
    expect(find.textContaining('left'), findsOneWidget, reason: 'honest ETA');

    await tester.tap(find.byKey(const Key('model-cancel-silero-vad')));
    await tester.pumpAndSettle();

    expect(store.downloadedIds, isNot(contains('silero-vad')));
    expect(store.partial['silero-vad'], greaterThan(0));
    expect(find.textContaining('Paused'), findsOneWidget);
    expect(
      find.text('Resume'),
      findsOneWidget,
      reason: 'the kept partial is offered for resume',
    );
  });

  testWidgets('delete asks, then removes', (tester) async {
    final store = await pump(
      tester,
      store: FakeModelStore(downloadedIds: {'whisper-tiny-ggml'}),
    );
    await tester.tap(find.byKey(const Key('model-delete-whisper-tiny-ggml')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.tap(find.text('Remove model'));
    await tester.pumpAndSettle();

    expect(store.downloadedIds, isEmpty);
    expect(
      find.byKey(const Key('model-download-whisper-tiny-ggml')),
      findsOneWidget,
    );
  });

  testWidgets('translation pairs fold into one section that names each '
      'pair by its languages and credits their makers', (tester) async {
    await pump(tester,
        store: FakeModelStore(downloadedIds: {'opus-mt-en-de'}));
    expect(find.byKey(const Key('model-download-opus-mt-en-ROMANCE')),
        findsNothing, reason: 'folded until opened');
    expect(find.textContaining('1 of 62 downloaded'), findsOneWidget);

    await tester.scrollUntilVisible(
        find.byKey(const Key('models-translation')), 200);
    await tester.tap(find.byKey(const Key('models-translation')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('opus-mt-credit')), findsOneWidget);
    expect(translationModelsCredit, contains('CC-BY 4.0'));
    expect(translationModelsCredit, contains('Apache-2.0'));
    expect(translationModelsCredit,
        contains('https://github.com/Helsinki-NLP/Opus-MT'));
    expect(
        translationModelsCredit,
        contains('Japanese to and from English: ElanMT-BT by ELAN MITSUA '
            'Project / Abstract Engine, under CC BY-SA 4.0, converted to '
            'ONNX by Trellis'));
    expect(translationModelsCredit,
        contains('https://huggingface.co/Mitsua/elan-mt-bt-en-ja'));
    expect(translationModelsCredit,
        contains('https://huggingface.co/Mitsua/elan-mt-bt-ja-en'));
    expect(
        translationModelsCredit,
        contains('The converted files, the licence text and the export '
            'recipe are kept at https://github.com/levitatingflyfisher/'
            'Trellis/releases/tag/models-enja-1 and '
            '.../releases/tag/models-jaen-1, which are never deleted.'));

    final pt = find.text('English to Portuguese translation, offline');
    await tester.scrollUntilVisible(pt, 200);
    expect(pt, findsOneWidget);
  });

  testWidgets('the Japanese pair says Trellis converted it, from what, and '
      'under which licence; a pair taken as published says nothing of the '
      'kind', (tester) async {
    await pump(tester);
    await tester.scrollUntilVisible(
        find.byKey(const Key('models-translation')), 200);
    await tester.tap(find.byKey(const Key('models-translation')));
    await tester.pumpAndSettle();

    final ja = find.text('English to Japanese translation, offline');
    await tester.scrollUntilVisible(ja, 200);
    expect(ja, findsOneWidget);
    expect(
        find.byKey(const Key('model-converted-elanmt-bt-en-ja')), findsOneWidget);
    expect(find.text('Converted by Trellis from ElanMT-BT '
        '(Mitsua/elan-mt-bt-en-ja)'), findsOneWidget);
    expect(find.textContaining('CC-BY-SA-4.0'), findsNWidgets(2),
        reason: 'both Japanese pairs, and no other');
    expect(find.byKey(const Key('model-converted-opus-mt-en-de')), findsNothing);

    final jaEn = find.text('Japanese to English translation, offline');
    await tester.scrollUntilVisible(jaEn, 200);
    expect(jaEn, findsOneWidget);
    expect(find.byKey(const Key('model-converted-elanmt-bt-ja-en')),
        findsOneWidget);
    expect(find.text('Converted by Trellis from ElanMT-BT '
        '(Mitsua/elan-mt-bt-ja-en)'), findsOneWidget);
  });

  testWidgets('a pair downloaded before its config files were registered '
      'fetches them quietly on open and reads as downloaded', (tester) async {
    final spec = ModelRegistry.starter().byId('opus-mt-en-de')!;
    final store = FakeModelStore();
    store.partial[spec.id] = spec.sizeBytes - 2000; // only the configs missing
    await pump(tester, store: store);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(store.downloadsStarted, [spec.id],
        reason: 'no consent dialog for a few KB of an already-kept model');
    expect(find.byKey(const Key('consent-dialog')), findsNothing);
    expect(find.textContaining('1 of 62 downloaded'), findsOneWidget);
  });

  testWidgets('a downloaded pair whose decoder was re-pinned reads as an '
      'update with its download size, never as not downloaded or an error',
      (tester) async {
    final spec = ModelRegistry.starter().byId('opus-mt-en-es')!;
    final decoder = spec.files[1];
    final store = FakeModelStore();
    store.installed[spec.id] = spec.sizeBytes - decoder.bytes;
    await pump(tester, store: store);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(store.downloadsStarted, isEmpty,
        reason: 'a new decoder is a real download: it waits to be asked');
    expect(find.textContaining('1 update available'), findsOneWidget);

    await tester.scrollUntilVisible(
        find.byKey(const Key('models-translation')), 200);
    await tester.tap(find.byKey(const Key('models-translation')));
    await tester.pumpAndSettle();
    final state = find.byKey(Key('model-state-${spec.id}'));
    await tester.scrollUntilVisible(state, 200);
    expect(tester.widget<Text>(state).data,
        'Update available: ${formatBytes(decoder.bytes)}');
    expect(find.byKey(Key('model-delete-${spec.id}')), findsOneWidget,
        reason: 'what is kept can still be removed');

    await tester.tap(find.byKey(Key('model-download-${spec.id}')));
    await tester.pumpAndSettle();
    expect(find.textContaining('(${formatBytes(decoder.bytes)})'),
        findsOneWidget,
        reason: 'the consent names the update size, not the whole pair');
    await tester.tap(find.byKey(const Key('consent-accept')));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(store.downloadsStarted, [spec.id]);
    expect(tester.widget<Text>(state).data, 'On this device');
  });
}
