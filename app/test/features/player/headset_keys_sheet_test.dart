import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/headset_keys.dart';
import 'package:trellis/features/player/headset_keys_sheet.dart';

/// The Headphone buttons sheet (1.6.0): one setting per incoming key, in
/// plain words, saying what cannot be told apart.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> pump(WidgetTester tester) async {
    // Tall enough to show the whole sheet: its list builds only what is
    // on screen, and these tests are about every part of it.
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: HeadsetKeysSheet(store: HeadsetKeysStore(db)))));
    await tester.pumpAndSettle();
  }

  HeadsetAction chosen(WidgetTester tester, String group) => tester
      .widget<RadioGroup<HeadsetAction>>(find.byKey(Key('headset-$group')))
      .groupValue!;

  testWidgets('says which tap each key usually is, shows the owner’s '
      'defaults, and says left and right cannot be told apart',
      (tester) async {
    await pump(tester);

    expect(find.text('Headphone buttons'), findsOneWidget);
    expect(find.textContaining('double tap'), findsOneWidget);
    expect(find.textContaining('triple tap'), findsOneWidget);
    expect(chosen(tester, 'next'), HeadsetAction.forward30);
    expect(chosen(tester, 'previous'), HeadsetAction.nextEpisode);
    expect(
        find.textContaining('can’t tell the left earbud from the right'),
        findsOneWidget);
    expect(
        tester
            .widget<SwitchListTile>(
                find.byKey(const Key('headset-count-clicks')))
            .value,
        isFalse);
  });

  testWidgets('a choice for one key is remembered and leaves the other '
      'alone', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const Key('headset-next-back15')));
    await tester.pumpAndSettle();

    expect(chosen(tester, 'next'), HeadsetAction.back15);
    expect(chosen(tester, 'previous'), HeadsetAction.nextEpisode);
    final keys = await HeadsetKeysStore(db).read();
    expect(keys.next, HeadsetAction.back15);
    expect(keys.previous, HeadsetAction.nextEpisode);
  });

  testWidgets('counting clicks is a switch that says what it costs',
      (tester) async {
    await pump(tester);
    final toggle = find.byKey(const Key('headset-count-clicks'));
    await tester.ensureVisible(toggle);
    expect(find.textContaining('wait a moment'), findsOneWidget);

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    expect((await HeadsetKeysStore(db).read()).countClicks, isTrue);
  });

  testWidgets('fits a narrow phone at large text without running off the '
      'edge', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!),
        home: Scaffold(body: HeadsetKeysSheet(store: HeadsetKeysStore(db)))));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
