import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loom_core/loom_core.dart' as core;
import 'package:openhearth_design/openhearth_design.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/river/river_decay.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/scripted_fetcher.dart';

/// The river sheds leaves as ephemera decay (proposal-2 §12) — deletion made
/// visible and calm. The presentation is a pure mapping over the SAME day
/// arithmetic the boot sweep executes (loom_core.sweepEphemera): a leaf that
/// fades as decay approaches, and a one-line drift notice on the last two
/// days only. No countdown before that, no red, no badges — ADR-0003.
void main() {
  // ───── the pure decay-presentation model ─────

  group('ephemeraDaysLeft', () {
    test('counts down from first light to the boundary day', () {
      // Day it arrives: the full 30-day window plus the boundary day.
      expect(ephemeraDaysLeft(firstSeenEpochDay: 100, todayEpochDay: 100), 31);
      expect(ephemeraDaysLeft(firstSeenEpochDay: 100, todayEpochDay: 129), 2);
      // The boundary day itself survives (the sweep law) — last day of life.
      expect(ephemeraDaysLeft(firstSeenEpochDay: 100, todayEpochDay: 130), 1);
      expect(ephemeraDaysLeft(firstSeenEpochDay: 100, todayEpochDay: 131), 0);
    });

    test('reaches zero exactly when the sweep law takes the ephemeron', () {
      // The presentation must never disagree with the deletion it narrates.
      for (var age = 0; age <= 40; age++) {
        final swept = core.sweepEphemera([
          const core.Work(
              id: 'w',
              kind: core.WorkKind.episode,
              persistence: core.Persistence.ephemeron,
              firstSeenEpochDay: 100)
        ], todayEpochDay: 100 + age).isNotEmpty;
        final daysLeft =
            ephemeraDaysLeft(firstSeenEpochDay: 100, todayEpochDay: 100 + age);
        expect(daysLeft <= 0, swept, reason: 'age $age');
      }
    });

    test('honours a custom retention window', () {
      expect(
          ephemeraDaysLeft(
              firstSeenEpochDay: 100, todayEpochDay: 100, retentionDays: 7),
          8);
      expect(
          ephemeraDaysLeft(
              firstSeenEpochDay: 100, todayEpochDay: 107, retentionDays: 7),
          1);
    });
  });

  group('leafOpacity', () {
    test('a fresh leaf is fully there', () {
      expect(leafOpacity(31), 1.0);
    });

    test('fades monotonically as decay approaches', () {
      for (var d = 31; d > 0; d--) {
        expect(leafOpacity(d - 1), lessThan(leafOpacity(d)),
            reason: 'daysLeft ${d - 1} vs $d');
      }
    });

    test('stays inside [floor, 1] for any input, even out of range', () {
      for (var d = -5; d <= 40; d++) {
        expect(leafOpacity(d), inInclusiveRange(kLeafMinOpacity, 1.0),
            reason: 'daysLeft $d');
      }
    });

    test('the calm floor keeps the leaf visible to the end', () {
      expect(leafOpacity(0), kLeafMinOpacity);
      expect(kLeafMinOpacity, greaterThan(0.0));
      expect(kLeafMinOpacity, lessThan(1.0));
    });
  });

  group('driftSubtitle', () {
    test('is silent outside the last two days — no countdown urgency', () {
      expect(driftSubtitle(31), isNull);
      expect(driftSubtitle(3), isNull);
    });

    test('names the last two days in plain, calm words', () {
      expect(driftSubtitle(2), 'drifts away in 2 days');
      expect(driftSubtitle(1), 'drifts away in 1 day');
      // Overdue but not yet swept (the sweep runs at boot): still calm.
      expect(driftSubtitle(0), 'drifts away in 1 day');
    });
  });

  // ───── the river tiles ─────

  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  int todayEpochDay() =>
      DateTime.now().toUtc().millisecondsSinceEpoch ~/
      Duration.millisecondsPerDay;

  Future<int> seedItem(
      {required int profileId,
      required int feedId,
      required String title,
      required int firstSeenEpochDay,
      required int publishedAtMs,
      String persistence = 'ephemeron'}) async {
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'article',
        title: title,
        persistence: persistence,
        firstSeenEpochDay: firstSeenEpochDay);
    await db.feedsDao.insertEpisode(
        workId: workId,
        feedId: feedId,
        guid: 'guid-$title',
        publishedAtMs: publishedAtMs);
    return workId;
  }

  /// Four ephemera across the decay arc (all inside the sweep's mercy) and
  /// one promoted work old enough that decay would long have taken it.
  Future<({int fresh, int outside, int twoDays, int lastDay, int promoted})>
      seedSpread() async {
    final profileId = await db.profilesDao.create('Ada');
    final feedId = await db.feedsDao
        .insertFeed(profileId: profileId, url: 'https://cast.test/feed');
    final today = todayEpochDay();
    final fresh = await seedItem(
        profileId: profileId,
        feedId: feedId,
        title: 'Fresh today',
        firstSeenEpochDay: today,
        publishedAtMs: 5000);
    final outside = await seedItem(
        profileId: profileId,
        feedId: feedId,
        title: 'Three days left',
        firstSeenEpochDay: today - 28,
        publishedAtMs: 4000);
    final twoDays = await seedItem(
        profileId: profileId,
        feedId: feedId,
        title: 'Two days left',
        firstSeenEpochDay: today - 29,
        publishedAtMs: 3000);
    final lastDay = await seedItem(
        profileId: profileId,
        feedId: feedId,
        title: 'Boundary day',
        firstSeenEpochDay: today - 30,
        publishedAtMs: 2000);
    final promoted = await seedItem(
        profileId: profileId,
        feedId: feedId,
        title: 'Kept long ago',
        firstSeenEpochDay: today - 200,
        publishedAtMs: 1000,
        persistence: 'work');
    return (
      fresh: fresh,
      outside: outside,
      twoDays: twoDays,
      lastDay: lastDay,
      promoted: promoted
    );
  }

  Future<void> openRiver(WidgetTester tester) async {
    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((u, h) => textResponse('')),
        createPlayer: () => FakeEpisodePlayer()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('River'));
    await tester.pumpAndSettle();
  }

  testWidgets('the drift line appears only inside the last two days, '
      'and never on a promoted work', (tester) async {
    final ids = await seedSpread();
    await openRiver(tester);

    expect(find.byKey(Key('drift-${ids.fresh}')), findsNothing);
    expect(find.byKey(Key('drift-${ids.outside}')), findsNothing,
        reason: 'three days out is still outside the window');
    expect(
        tester.widget<Text>(find.byKey(Key('drift-${ids.twoDays}'))).data,
        'drifts away in 2 days');
    expect(
        tester.widget<Text>(find.byKey(Key('drift-${ids.lastDay}'))).data,
        'drifts away in 1 day');
    expect(find.byKey(Key('drift-${ids.promoted}')), findsNothing,
        reason: 'works persist — there is nothing to narrate');

    // Calm means calm: the notice is never set in the error red.
    final style =
        tester.widget<Text>(find.byKey(Key('drift-${ids.lastDay}'))).style;
    expect(style?.color, isNot(OhColors.red500));
  });

  testWidgets('the leaf fades toward decay but never below the calm floor, '
      'and promoted works carry no leaf', (tester) async {
    final ids = await seedSpread();
    await openRiver(tester);

    double leafOf(int id) =>
        tester.widget<Opacity>(find.byKey(Key('leaf-$id'))).opacity;

    expect(leafOf(ids.fresh), moreOrLessEquals(1.0));
    expect(leafOf(ids.outside), lessThan(leafOf(ids.fresh)));
    expect(leafOf(ids.twoDays), lessThan(leafOf(ids.outside)));
    expect(leafOf(ids.lastDay), lessThan(leafOf(ids.twoDays)));
    expect(leafOf(ids.lastDay), greaterThanOrEqualTo(kLeafMinOpacity));

    expect(find.byKey(Key('leaf-${ids.promoted}')), findsNothing,
        reason: 'a promoted work persists — no decay to show');
  });
}
