import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/captures_screen.dart';
import 'package:trellis/features/player/player_controller.dart';

import '../support/fake_player.dart';

/// The study crown, Phase 2's other UI half: the captures list per episode.
/// Each row shows its sentence context (the ±1-sentence window around the
/// bound segment) and jumps playback on tap; a capture taken before a
/// transcript existed shows an honest "transcript pending" line instead of
/// a fabricated one.
void main() {
  late AppDatabase db;
  late FakeEpisodePlayer fakePlayer;
  late PlayerController controller;
  late int profileId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    fakePlayer = FakeEpisodePlayer();
    profileId = await db.profilesDao.create('Ada');
    controller = PlayerController(
        db: db, profileId: profileId, createPlayer: () => fakePlayer);
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
  });

  Future<Work> seedAlignedEpisode() async {
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Ep 1',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/1.mp3');
    await db.spineDao.insertSegments(workId, const [
      (idx: 0, kind: 'prose', text: 'Intro line.'),
      (idx: 1, kind: 'prose', text: 'The important bit.'),
      (idx: 2, kind: 'prose', text: 'Outro line.'),
    ]);
    await db.spineDao.insertAlignments(workId, const [
      (segmentIdx: 0, tStartMs: 0, tEndMs: 5000),
      (segmentIdx: 1, tStartMs: 5000, tEndMs: 10000),
      (segmentIdx: 2, tStartMs: 10000, tEndMs: 15000),
    ]);
    return (await db.spineDao.worksOf(profileId)).single;
  }

  testWidgets('empty state names what is missing, not a bare "no data"',
      (tester) async {
    final work = await seedAlignedEpisode();
    await tester.pumpWidget(MaterialApp(
        home: CapturesScreen(db: db, controller: controller, work: work)));
    await tester.pumpAndSettle();

    expect(find.textContaining('capture'), findsOneWidget);
  });

  testWidgets(
      'a bound capture shows the ±1-sentence window around its segment',
      (tester) async {
    final work = await seedAlignedEpisode();
    await db.capturesDao.capture(
        profileId: profileId, workId: work.id, positionMs: 6000, nowMs: 1);

    await tester.pumpWidget(MaterialApp(
        home: CapturesScreen(db: db, controller: controller, work: work)));
    await tester.pumpAndSettle();

    expect(find.textContaining('Intro line.'), findsOneWidget);
    expect(find.textContaining('The important bit.'), findsOneWidget);
    expect(find.textContaining('Outro line.'), findsOneWidget);
  });

  testWidgets(
      'an unbound capture (no transcript yet) says so honestly, never a '
      'fabricated sentence', (tester) async {
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Ep 2',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/2.mp3');
    final work = (await db.spineDao.worksOf(profileId)).single;
    await db.capturesDao
        .capture(profileId: profileId, workId: workId, positionMs: 4200, nowMs: 1);

    await tester.pumpWidget(MaterialApp(
        home: CapturesScreen(db: db, controller: controller, work: work)));
    await tester.pumpAndSettle();

    expect(find.textContaining('transcript'), findsOneWidget);
  });

  testWidgets('tapping a capture jumps playback to its exact position',
      (tester) async {
    final work = await seedAlignedEpisode();
    await db.capturesDao.capture(
        profileId: profileId, workId: work.id, positionMs: 6500, nowMs: 1);

    await tester.pumpWidget(MaterialApp(
        home: CapturesScreen(db: db, controller: controller, work: work)));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('The important bit.'));
    await tester.pumpAndSettle();

    expect(fakePlayer.loadedUrl, 'https://cast.test/1.mp3');
    expect(fakePlayer.log.last, 'seek:6500');
  });
}
