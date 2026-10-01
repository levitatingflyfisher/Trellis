import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/reader/reader_screen.dart';

import '../support/fake_player.dart';

/// Campaign 9 Phase 7 ("the reader follows the player"), reworked in
/// 1.5.8: when audio for THIS work is playing — already under way when
/// the reader opens, or started via Listen — the reader's cursor follows
/// the voice word by word (ADR-0002), and the page scrolls with it. The
/// user's hand (a drag, an RSVP tap, the pacer) takes the cursor back;
/// only then is there a button, "Back to audio", which always means that
/// one action, identically in RSVP, Page > Line and Page > Follow along.
/// The pure time <-> word mapping is covered in
/// `test/reader/reader_logic_test.dart`.
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
    // Every word is unique, deliberately: word 0 of the whole document
    // ('First') renders as the print reader's DROP CAP
    // (reader_print_test.dart), not a plain `cursor-word`-keyed Text, so
    // tests that need a tappable, cursor-word-checkable word in segment 0
    // reach for 'alpha.' instead.
    await db.spineDao.insertSegments(workId, const [
      (idx: 0, kind: 'prose', text: 'First alpha.'),
      (idx: 1, kind: 'prose', text: 'Second beta.'),
    ]);
    await db.spineDao.insertAlignments(workId, const [
      (segmentIdx: 0, tStartMs: 0, tEndMs: 10000),
      (segmentIdx: 1, tStartMs: 10000, tEndMs: 20000),
    ]);
    return (await db.spineDao.worksOf(profileId)).single;
  }

  /// Opens the reader in [mode]: 'rsvp', or Page with 'follow' or
  /// 'line' as its highlight.
  Future<void> openIn(WidgetTester tester, Work work, String mode) async {
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(
            db: db, profileId: profileId, work: work, player: controller)));
    await tester.pumpAndSettle();
    if (mode == 'rsvp') return;
    await tester.tap(find.byKey(const Key('mode-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key(
        mode == 'line' ? 'highlight-item-line' : 'highlight-item-follow')));
    await tester.pumpAndSettle();
  }

  Future<void> openInScroll(WidgetTester tester, Work work) =>
      openIn(tester, work, 'follow');

  final backToAudio = find.byKey(const Key('back-to-audio'));

  /// Thirty aligned one-second segments, "Para 0." to "Para 29.": enough
  /// that most of them are off screen, so a catch-up has to really scroll.
  Future<Work> seedLongEpisode() async {
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Long episode',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/long.mp3');
    await db.spineDao.insertSegments(workId, [
      for (var i = 0; i < 30; i++) (idx: i, kind: 'prose', text: 'Para $i.')
    ]);
    await db.spineDao.insertAlignments(workId, [
      for (var i = 0; i < 30; i++)
        (segmentIdx: i, tStartMs: i * 1000, tEndMs: (i + 1) * 1000)
    ]);
    return (await db.spineDao.worksOf(profileId))
        .firstWhere((w) => w.id == workId);
  }

  /// Whether segment [blockPos]'s tile is actually on screen, not merely
  /// built somewhere in the scroll view's cache.
  bool tileOnScreen(WidgetTester tester, int blockPos) {
    final f = find.byKey(Key('segment-tile-$blockPos'));
    if (f.evaluate().isEmpty) return false;
    final r = tester.getRect(f);
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    return r.bottom > 0 && r.top < screen.height;
  }

  String? rsvpWord(WidgetTester tester) {
    String part(String k) => tester.widget<Text>(find.byKey(Key(k))).data!;
    return '${part('rsvp-bef')}${part('rsvp-piv')}${part('rsvp-aft')}';
  }

  String? cursorWordText(WidgetTester tester) {
    final finder = find.byKey(const Key('cursor-word'));
    if (finder.evaluate().isEmpty) return null;
    return tester.widget<Text>(finder).data;
  }

  group('there is no button when there is nothing to come back to', () {
    testWidgets('no player wired in', (tester) async {
      final work = await seedAlignedEpisode();
      await tester.pumpWidget(MaterialApp(
          home: ReaderScreen(db: db, profileId: profileId, work: work)));
      await tester.pumpAndSettle();

      expect(backToAudio, findsNothing);
    });

    testWidgets('a player is wired in but not playing this work',
        (tester) async {
      final work = await seedAlignedEpisode();
      await openInScroll(tester, work);

      expect(backToAudio, findsNothing);
    });

    testWidgets('the work has no alignments at all', (tester) async {
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'note',
          title: 'Plain note',
          persistence: 'work',
          firstSeenEpochDay: 100);
      await db.spineDao
          .insertSegments(workId, const [(idx: 0, kind: 'prose', text: 'Hi.')]);
      final work = (await db.spineDao.worksOf(profileId)).single;
      await controller.playWork(work);
      await openInScroll(tester, work);

      expect(backToAudio, findsNothing);
    });

    testWidgets('while following, in every mode', (tester) async {
      final work = await seedAlignedEpisode();
      await controller.playWork(work);
      for (final mode in ['rsvp', 'follow', 'line']) {
        await openIn(tester, work, mode);
        expect(backToAudio, findsNothing, reason: mode);
      }
    });
  });

  testWidgets(
      'audio already playing for this work attaches on open, and the lit '
      'word moves through each segment with the voice', (tester) async {
    final work = await seedAlignedEpisode();
    await controller.playWork(work);

    await openInScroll(tester, work);

    fakePlayer.emitPosition(const Duration(milliseconds: 10500));
    await tester.pump();
    expect(cursorWordText(tester), 'Second');

    // No stamps: the word moves evenly across the segment's span.
    fakePlayer.emitPosition(const Duration(seconds: 15));
    await tester.pump();
    expect(cursorWordText(tester), 'beta.');
  });

  testWidgets("whisper's word stamps lead the lit word, as the transcript "
      'view lit it', (tester) async {
    final work = await seedAlignedEpisode();
    await db.customStatement(
        "UPDATE alignments SET word_timings = CAST(? AS BLOB) "
        'WHERE work_id = ? AND segment_idx = 1',
        ['[["Second",10000,19000],["beta.",19000,20000]]', work.id]);
    await controller.playWork(work);
    await openInScroll(tester, work);

    fakePlayer.emitPosition(const Duration(seconds: 15));
    await tester.pump();
    expect(cursorWordText(tester), 'Second');

    fakePlayer.emitPosition(const Duration(milliseconds: 19100));
    await tester.pump();
    expect(cursorWordText(tester), 'beta.');
  });

  for (final speed in [3.0, 4.0]) {
    testWidgets(
        'at ${speed.toInt()}x the lit word keeps up between the player\'s '
        'coarse ticks', (tester) async {
      final work = await seedLongEpisode();
      await controller.playWork(work);
      await controller.setSpeed(speed);
      await openInScroll(tester, work);
      expect(fakePlayer.lastSpeed, speed,
          reason: 'the reader drives the shared speed, not its own');

      // A real player ticks at most five times a second; at this speed
      // the voice crosses several segments between two ticks. The page
      // must read the playhead every frame, not wait for the next tick.
      for (var seg = 1; seg <= 6; seg++) {
        fakePlayer.movePositionQuietly(Duration(milliseconds: seg * 1000));
        await tester.pump(const Duration(milliseconds: 16));
        expect(
            tester
                .widget<Container>(find.byKey(Key('segment-tile-$seg'),
                    skipOffstage: false))
                .color,
            isNotNull,
            reason: 'segment $seg is the current one');
      }
    });
  }

  testWidgets('Listen also attaches following', (tester) async {
    final work = await seedAlignedEpisode();
    await openInScroll(tester, work);

    await tester.tap(find.text('alpha.')); // segment 0, not the drop cap
    await tester.pump();
    await tester.tap(find.byTooltip('Listen'));
    await tester.pumpAndSettle();

    fakePlayer.emitPosition(const Duration(milliseconds: 10500));
    await tester.pump();

    expect(cursorWordText(tester), 'Second');
    expect(backToAudio, findsNothing);
  });

  testWidgets('tapping a word on Page seeks the audio to that word and keeps '
      'following', (tester) async {
    final work = await seedAlignedEpisode();
    await controller.playWork(work);
    await openInScroll(tester, work);
    fakePlayer.log.clear();

    await tester.tap(find.text('beta.'));
    await tester.pumpAndSettle();

    expect(fakePlayer.log, contains('seek:15000'),
        reason: "beta. is the second half of segment 1's span");
    expect(backToAudio, findsNothing);

    fakePlayer.emitPosition(const Duration(milliseconds: 500));
    await tester.pump();
    expect(cursorWordText(tester), isNot('beta.'),
        reason: 'still following: the next tick moves the cursor');
  });

  testWidgets('tapping a word on Line seeks too', (tester) async {
    final work = await seedAlignedEpisode();
    await controller.playWork(work);
    await openIn(tester, work, 'line');
    fakePlayer.log.clear();

    // Past the end of the line's text: the last word, "beta.".
    await tester.tap(find.byKey(const Key('segment-tile-1')));
    await tester.pumpAndSettle();

    expect(fakePlayer.log, contains('seek:15000'));
    expect(backToAudio, findsNothing);
  });

  testWidgets('the pacer is a hand on the cursor: Play in RSVP detaches',
      (tester) async {
    final work = await seedAlignedEpisode();
    await controller.playWork(work);
    await openIn(tester, work, 'rsvp');

    await tester.tap(find.byKey(const Key('play-toggle')));
    await tester.pump();

    expect(backToAudio, findsOneWidget);
    await tester.tap(find.byKey(const Key('play-toggle'))); // stop the pacer
    await tester.pump();
  });

  // The catch-up, identical in every mode: the hand takes the cursor, the
  // voice runs on far ahead, and Back to audio puts the cursor (and, on
  // Page, the page) on the voice again, then goes away.
  for (final mode in ['rsvp', 'follow', 'line']) {
    testWidgets('Back to audio catches up in $mode', (tester) async {
      final work = await seedLongEpisode();
      await controller.playWork(work);
      await openIn(tester, work, mode);
      expect(backToAudio, findsNothing);

      if (mode == 'rsvp') {
        final rect = tester.getRect(find.byKey(const Key('reader-tapzone')));
        await tester
            .tapAt(Offset(rect.left + rect.width * 5 / 6, rect.center.dy));
      } else {
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
      }
      await tester.pumpAndSettle();
      expect(backToAudio, findsOneWidget, reason: 'the hand took the cursor');

      // The voice runs on to segment 25 while the reader looks elsewhere.
      fakePlayer.emitPosition(const Duration(milliseconds: 25100));
      await tester.pumpAndSettle();
      if (mode != 'rsvp') expect(tileOnScreen(tester, 25), isFalse);

      await tester.tap(backToAudio);
      await tester.pumpAndSettle();

      expect(backToAudio, findsNothing);
      if (mode == 'rsvp') {
        expect(rsvpWord(tester), 'Para');
        fakePlayer.emitPosition(const Duration(milliseconds: 25600));
        await tester.pump();
        expect(rsvpWord(tester), '25.', reason: 'following again');
      } else {
        expect(tileOnScreen(tester, 25), isTrue,
            reason: 'the page re-centred on the voice');
        final tile = find.byKey(const Key('segment-tile-25'));
        if (mode == 'follow') {
          expect(tester.widget<Container>(tile).color, isNotNull);
        } else {
          expect(
              find.descendant(
                  of: tile, matching: find.byKey(const Key('line-paced-highlight'))),
              findsOneWidget);
        }
      }
    });
  }

  testWidgets('while following, the page scrolls along with the voice',
      (tester) async {
    final work = await seedLongEpisode();
    await controller.playWork(work);
    await openInScroll(tester, work);
    expect(tileOnScreen(tester, 20), isFalse);

    for (var seg = 1; seg <= 20; seg++) {
      fakePlayer.emitPosition(Duration(milliseconds: seg * 1000 + 100));
      await tester.pumpAndSettle();
    }

    expect(tileOnScreen(tester, 20), isTrue);
    expect(backToAudio, findsNothing);
  });

  testWidgets(
      'playback moving to a different work detaches quietly, without '
      'throwing', (tester) async {
    final work = await seedAlignedEpisode();
    await controller.playWork(work);
    await openInScroll(tester, work);

    final otherWorkId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Ep 2',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/2.mp3');
    final otherWork = (await db.spineDao.worksOf(profileId))
        .firstWhere((w) => w.id == otherWorkId);
    await controller.playWork(otherWork);
    await tester.pump();

    expect(backToAudio, findsNothing,
        reason: 'nothing of this work is playing to go back to');
  });

  testWidgets(
      'disposing the reader while following removes the listener — a '
      'later tick on the (now-detached) controller never throws',
      (tester) async {
    final work = await seedAlignedEpisode();
    await controller.playWork(work);
    await openInScroll(tester, work);

    await tester.pumpWidget(const SizedBox()); // tears the reader down
    await tester.pumpAndSettle();

    expect(() => fakePlayer.emitPosition(const Duration(seconds: 15)),
        returnsNormally);
  });
}
