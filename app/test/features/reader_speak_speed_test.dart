import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/reader/reader_screen.dart';

import '../support/fake_player.dart';
import '../support/fake_tts.dart';

/// 1.5.8: read-aloud uses the same shared speed control as listening,
/// and the lit word sweeps through the sentence being spoken at that
/// speed instead of sitting on its first word — re-anchored at every
/// sentence start, and never running ahead into the next sentence.
void main() {
  late AppDatabase db;
  late PlayerController controller;
  late int profileId;
  late Work work;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    controller = PlayerController(
        db: db, profileId: profileId, createPlayer: FakeEpisodePlayer.new);
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'note',
        title: 'A note',
        persistence: 'work',
        firstSeenEpochDay: 100);
    await db.spineDao.insertSegments(workId, const [
      (
        idx: 0,
        kind: 'prose',
        text: 'Start here now. One two three four five six seven eight. '
            'Next sentence.'
      ),
    ]);
    work = (await db.spineDao.worksOf(profileId)).single;
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
  });

  String? cursorWord(WidgetTester tester) {
    final f = find.byKey(const Key('cursor-word'));
    return f.evaluate().isEmpty ? null : tester.widget<Text>(f).data;
  }

  const words = [
    'One', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight.' //
  ];

  /// Opens Page on the note, starts reading aloud at [speed], and lets
  /// the first sentence ("Start here now.", 1s) finish.
  Future<FakeTtsSpeaker> readAloudAt(WidgetTester tester, double speed) async {
    final tts = FakeTtsSpeaker(utteranceLength: const Duration(seconds: 3));
    await controller.setSpeed(speed);
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(
            db: db,
            profileId: profileId,
            work: work,
            player: controller,
            tts: tts,
            openOnPage: true)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reader-speed')), findsOneWidget,
        reason: 'the shared speed control sits by read-aloud too');
    await tester.tap(find.byKey(const Key('reader-play')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3)); // "Start here now."
    await tester.pump();
    return tts;
  }

  for (final speed in [3.0, 4.0]) {
    testWidgets('at ${speed.toInt()}x the voice runs at that speed and the '
        'lit word keeps to the sentence', (tester) async {
      final tts = await readAloudAt(tester, speed);
      expect(tts.rate, speed / 2,
          reason: "flutter_tts's 0.5 is a voice's normal pace");
      expect(cursorWord(tester), 'One');

      // Halfway through the sentence's estimated time at this speed.
      await tester.pump(Duration(milliseconds: (1400 / speed).round()));
      final mid = words.indexOf(cursorWord(tester) ?? '');
      expect(mid, inInclusiveRange(2, 6), reason: 'moving through it');

      // Well past the estimate but still speaking: held on its last word.
      await tester.pump(const Duration(milliseconds: 1500));
      expect(cursorWord(tester), 'eight.');

      // The next sentence starts: the sweep re-anchors there.
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(cursorWord(tester), isIn(['Next', 'sentence.']));

      await tester.tap(find.byKey(const Key('reader-play'))); // stop
      await tester.pumpAndSettle();
    });
  }

  testWidgets('leaving mid-sentence saves the sentence\'s start, as a stop '
      'does', (tester) async {
    await readAloudAt(tester, 4.0);
    await tester.pump(const Duration(milliseconds: 500));
    expect(cursorWord(tester), isNot('One'), reason: 'the sweep moved on');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    final pos =
        await db.spineDao.position(profileId: profileId, workId: work.id);
    expect(pos!.wordIdx, 3, reason: '"One", where the sentence starts');
  });

  testWidgets('changing the speed while reading aloud changes the voice',
      (tester) async {
    final tts = await readAloudAt(tester, 1.0);
    expect(tts.rate, 0.5);
    await controller.setSpeed(2.0);
    await tester.pump();
    expect(tts.rate, 1.0);
    await tester.tap(find.byKey(const Key('reader-play')));
    await tester.pumpAndSettle();
  });
}
