import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhearth_design/openhearth_design.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/mini_player_bar.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/reader/reader_screen.dart';

import '../support/fake_player.dart';
import '../support/fake_tts.dart';

/// Campaign 9 Phase 0 — the device report: "the play/pause circles don't
/// have play/pause symbols in them, they're just blank circles." The
/// visual-loop golden render (kept as a self-guarded diagnostic in
/// test/visual/p0_repro_golden_test.dart) reproduced it and localized the
/// cause by isolation: `OhTheme`'s app-wide `ThemeData.iconTheme` sets
/// `color: primary` — the SAME color `IconButton.filled` fills its own
/// background with — so an unstyled `IconButton.filled` paints its glyph
/// in the exact color of the circle behind it. Not a missing icon; an
/// invisible one.
///
/// The app's two play/pause toggles (mini_player_bar.dart's transport
/// toggle and reader_screen.dart's RSVP toggle) have since migrated onto
/// `OhIconButton.filled` from `openhearth_design`, which pins the
/// high-contrast foreground itself; the fleet's C8 conformance check now
/// forbids a bare `IconButton.filled`/`IconButton.filledTonal` in `lib/`
/// so the collision can't reopen unnoticed.
///
/// This is the enforced regression gate (unconditional, unlike the
/// gitignored/env-guarded golden PNGs, which drift across machines and
/// can't gate CI): it reads the EFFECTIVE resolved icon color Flutter will
/// actually paint with — via `IconTheme.of` at the icon's own context, the
/// same resolution Flutter's renderer uses — and asserts it is the
/// high-contrast `onPrimary` token, not the collided `primary` one.
void main() {
  Color? effectiveIconColor(WidgetTester tester, Key iconButtonKey) {
    final iconFinder = find.descendant(
        of: find.byKey(iconButtonKey), matching: find.byType(Icon));
    final context = tester.element(iconFinder);
    return IconTheme.of(context).color;
  }

  group('MiniPlayerBar transport toggle', () {
    late AppDatabase db;
    late int profileId;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      profileId = await db.profilesDao.create('Ada');
    });
    tearDown(() => db.close());

    Future<PlayerController> playSomething() async {
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: 'Tides and Their Clocks',
          persistence: 'ephemeron',
          firstSeenEpochDay: 100,
          sourceUrl: 'https://cast.example.test/ep1.mp3');
      final feedId = await db.feedsDao.insertFeed(
          profileId: profileId, url: 'https://cast.example.test/feed.xml');
      await db.feedsDao.insertEpisode(
          workId: workId,
          feedId: feedId,
          guid: 'ep1',
          enclosureUrl: 'https://cast.example.test/ep1.mp3',
          publishedAtMs: 0);
      final work = (await db.spineDao.worksOf(profileId)).single;
      final player = FakeEpisodePlayer();
      final controller = PlayerController(
          db: db, profileId: profileId, createPlayer: () => player);
      await controller.playWork(work);
      return controller;
    }

    for (final theme in [
      (name: 'light', data: OhTheme.light()),
      (name: 'hearthDark', data: OhTheme.hearthDark()),
    ]) {
      testWidgets(
          "the play/pause glyph is visible (not the same color as its own "
          "fill) under OhTheme.${theme.name}()", (tester) async {
        final controller = await playSomething();
        addTearDown(controller.dispose);

        await tester.pumpWidget(MaterialApp(
          theme: theme.data,
          home: Scaffold(body: MiniPlayerBar(controller: controller)),
        ));
        await tester.pump();

        final onPrimary = theme.data.colorScheme.onPrimary;
        final primary = theme.data.colorScheme.primary;
        final resolved =
            effectiveIconColor(tester, const Key('player-toggle'));

        expect(resolved, isNot(primary),
            reason: 'the glyph must not render in the same color as the '
                "button's own fill — that is the blank-circle bug");
        expect(resolved, onPrimary,
            reason: 'OhIconButton.filled should paint its glyph with the '
                'high-contrast onPrimary token');
      });
    }
  });

  group('ReaderScreen RSVP toggle', () {
    late AppDatabase db;
    late int profileId;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      profileId = await db.profilesDao.create('Ada');
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'note',
          title: 'One Word',
          persistence: 'work',
          firstSeenEpochDay: 100,
          lang: 'en');
      await db.spineDao.insertSegments(
          workId, const [(idx: 0, kind: 'prose', text: 'One two three.')]);
    });
    tearDown(() => db.close());

    for (final theme in [
      (name: 'light', data: OhTheme.light()),
      (name: 'hearthDark', data: OhTheme.hearthDark()),
    ]) {
      testWidgets(
          "the RSVP play/pause glyph is visible under OhTheme.${theme.name}()",
          (tester) async {
        final work = (await db.spineDao.worksOf(profileId)).single;
        await tester.pumpWidget(MaterialApp(
          theme: theme.data,
          home: ReaderScreen(
              db: db,
              profileId: profileId,
              work: work,
              tts: FakeTtsSpeaker()),
        ));
        await tester.pumpAndSettle();

        final onPrimary = theme.data.colorScheme.onPrimary;
        final primary = theme.data.colorScheme.primary;
        final resolved = effectiveIconColor(tester, const Key('play-toggle'));

        expect(resolved, isNot(primary),
            reason: 'the glyph must not render in the same color as the '
                "button's own fill — that is the blank-circle bug");
        expect(resolved, onPrimary,
            reason: 'OhIconButton.filled should paint its glyph with the '
                'high-contrast onPrimary token');
      });
    }
  });
}
