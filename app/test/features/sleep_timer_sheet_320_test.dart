import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/player/sleep_timer_sheet.dart';

import '../support/fake_player.dart';

/// Campaign 9 Phase 1 — user: "Custo" (the "Custom..." button's label was
/// clipped by a hard `SizedBox(width: 100)` cell). House accessibility-
/// overflow law: sweep 320dp width and textScale 1.0→3.0, assert no
/// overflow AND the full string renders — the fleet's recurring wound
/// (rigid Row/Wrap children clipping at large text scale on narrow
/// screens).
void main() {
  testWidgets(
      'the sleep timer picker survives 320dp at textScale 1.0-3.0 with '
      'Custom... unclipped', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final profileId = await db.profilesDao.create('Ada');
    final player = FakeEpisodePlayer();
    final controller = PlayerController(
        db: db, profileId: profileId, createPlayer: () => player);
    addTearDown(controller.dispose);

    Future<double> customButtonWidthAt(double scale) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = scale;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SleepTimerSheet(controller: controller)),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull,
          reason: 'no RenderFlex overflow at 320dp/${scale}x');
      expect(find.text('Custom...'), findsOneWidget,
          reason: 'the label must render in full, not "Custo" — the '
              'reported clip');
      final width =
          tester.getSize(find.byKey(const Key('sleep-timer-custom'))).width;

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      return width;
    }

    final widthAt1x = await customButtonWidthAt(1.0);
    final widthAt2x = await customButtonWidthAt(2.0);
    final widthAt3x = await customButtonWidthAt(3.0);

    // A hard `SizedBox(width: 100)` cell pins every scale to exactly the
    // same width no matter how much wider "Custom..." needs to be — that
    // IS the reported clip. Sizing intrinsically means the button must
    // actually grow as text scale grows.
    expect(widthAt3x, greaterThan(widthAt1x),
        reason: 'the button must size to its content, not sit pinned at '
            'a fixed width while its text scale grows — a pinned width '
            "is exactly how \"Custom...\" clips to \"Custo\"");
    expect(widthAt2x, greaterThanOrEqualTo(widthAt1x));

    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
  });
}
