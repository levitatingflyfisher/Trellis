// Campaign 7 ("audiobooks are a door", ADR-0013): PlayerController's
// multi-file playback path. FakeEpisodePlayer models just_audio's gapless-
// playlist trust contract deliberately (see its own doc comment) — a test
// drives `emitCurrentIndex` per file boundary and `emitCompleted` exactly
// once, at the true end; nothing in the fake advances on its own.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/player_controller.dart';

import '../support/fake_player.dart';

void main() {
  late AppDatabase db;
  late FakeEpisodePlayer player;
  late PlayerController controller;
  late int profileId;
  final nowMs = DateTime.utc(2026, 8, 15, 9).millisecondsSinceEpoch;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    player = FakeEpisodePlayer();
    profileId = await db.profilesDao.create('Ada');
    controller = PlayerController(
      db: db,
      profileId: profileId,
      createPlayer: () => player,
      now: () => DateTime.fromMillisecondsSinceEpoch(nowMs),
    );
  });

  tearDown(() async {
    controller.dispose();
    await db.close();
  });

  Future<Work> seedAudiobook({
    String title = 'A Book',
    List<String> paths = const ['/audiobooks/1/0.mp3', '/audiobooks/1/1.mp3'],
    double? speedOverride,
  }) async {
    final workId = await db.spineDao.insertWork(
      profileId: profileId,
      kind: 'audiobook',
      title: title,
      persistence: 'work',
      firstSeenEpochDay: 100,
    );
    await db.audiobooksDao.insertAudiobook(workId);
    if (speedOverride != null) {
      await db.audiobooksDao.setSpeedOverride(workId, speedOverride);
    }
    await db.audiobooksDao.insertFiles(workId, paths);
    return (await db.spineDao.worksOf(profileId))
        .firstWhere((w) => w.id == workId);
  }

  group('PlayerController.playAudiobook', () {
    test('loads every file as one playlist, in fileIdx order, and plays',
        () async {
      final work = await seedAudiobook();
      await controller.playAudiobook(work);

      expect(player.loadedFilePaths,
          ['/audiobooks/1/0.mp3', '/audiobooks/1/1.mp3']);
      expect(player.loadedInitialIndex, 0);
      expect(player.loadedInitialPosition, Duration.zero);
      expect(player.playing, isTrue);
      expect(controller.current?.id, work.id);
      expect(controller.isAudiobook, isTrue);
      expect(controller.currentFileIdx, 0);
    });

    test('a never-opened book starts at file 0, offset 0', () async {
      final work = await seedAudiobook();
      await controller.playAudiobook(work);
      expect(player.loadedInitialIndex, 0);
      expect(player.loadedInitialPosition, Duration.zero);
    });

    test('re-tapping the current audiobook toggles pause/resume', () async {
      final work = await seedAudiobook();
      await controller.playAudiobook(work);
      await controller.playAudiobook(work);
      expect(player.playing, isFalse);
      await controller.playAudiobook(work);
      expect(player.playing, isTrue);
    });

    test('per-book speed override applies on load', () async {
      final work = await seedAudiobook(speedOverride: 1.75);
      await controller.playAudiobook(work);
      expect(player.lastSpeed, 1.75);
    });

    test('no speed override falls back to the global cycling speed',
        () async {
      final work = await seedAudiobook();
      await controller.playAudiobook(work);
      expect(player.lastSpeed, 1.0);
    });

    test('an audiobook with no files does nothing (never throws)', () async {
      final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'audiobook',
        title: 'Empty',
        persistence: 'work',
        firstSeenEpochDay: 100,
      );
      await db.audiobooksDao.insertAudiobook(workId);
      final work =
          (await db.spineDao.worksOf(profileId)).firstWhere((w) => w.id == workId);
      await controller.playAudiobook(work);
      expect(controller.current, isNull);
    });
  });

  group('the position law: (fileIdx, offset), round-tripped', () {
    test('currentFileIdx tracks the engine\'s own currentIndexStream',
        () async {
      final work = await seedAudiobook();
      await controller.playAudiobook(work);
      player.emitCurrentIndex(1);
      expect(controller.currentFileIdx, 1);
    });

    test('pausing on file 1 saves PlayerPositions with that fileIdx',
        () async {
      final work = await seedAudiobook();
      await controller.playAudiobook(work);
      player.emitCurrentIndex(1);
      player.emitPosition(const Duration(seconds: 42));
      await controller.toggle(); // pause -> saveProgress

      final pos = await db.feedsDao
          .playerPosition(profileId: profileId, workId: work.id);
      expect(pos!.fileIdx, 1);
      expect(pos.tMs, 42000);
    });

    test('a fresh controller (simulating app reopen) resumes at the exact '
        'stored (fileIdx, offset)', () async {
      final work = await seedAudiobook();
      await controller.playAudiobook(work);
      player.emitCurrentIndex(1);
      player.emitPosition(const Duration(seconds: 7));
      await controller.toggle(); // pause -> saveProgress
      // No explicit dispose here — the outer tearDown disposes `controller`
      // once; a second dispose would assert (ChangeNotifier forbids it).

      final freshPlayer = FakeEpisodePlayer();
      final freshController = PlayerController(
        db: db,
        profileId: profileId,
        createPlayer: () => freshPlayer,
        now: () => DateTime.fromMillisecondsSinceEpoch(nowMs),
      );
      addTearDown(freshController.dispose);
      await freshController.playAudiobook(work);

      expect(freshPlayer.loadedInitialIndex, 1);
      expect(freshPlayer.loadedInitialPosition, const Duration(seconds: 7));
    });

    test('episodes are unaffected — playerPosition.fileIdx defaults to 0',
        () async {
      final feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://cast.test/f');
      final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Ep',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/1.mp3',
      );
      await db.feedsDao.insertEpisode(
          workId: workId, feedId: feedId, guid: 'g', publishedAtMs: 1);
      final work =
          (await db.spineDao.worksOf(profileId)).firstWhere((w) => w.id == workId);
      await controller.playWork(work);
      player.emitPosition(const Duration(seconds: 5));
      await controller.toggle();
      final pos = await db.feedsDao
          .playerPosition(profileId: profileId, workId: work.id);
      expect(pos!.fileIdx, 0);
    });
  });

  group('capture() tags the current file index', () {
    test('a capture taken on file 1 stores fileIdx 1', () async {
      final work = await seedAudiobook();
      await controller.playAudiobook(work);
      player.emitCurrentIndex(1);
      player.emitPosition(const Duration(seconds: 12));
      final id = await controller.capture();
      final captures = await db.capturesDao.capturesOf(work.id);
      expect(captures.single.id, id);
      expect(captures.single.fileIdx, 1);
      expect(captures.single.positionMs, 12000);
    });

    test('an episode capture leaves fileIdx null', () async {
      final feedId = await db.feedsDao
          .insertFeed(profileId: profileId, url: 'https://cast.test/f');
      final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Ep',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/1.mp3',
      );
      await db.feedsDao.insertEpisode(
          workId: workId, feedId: feedId, guid: 'g', publishedAtMs: 1);
      final work =
          (await db.spineDao.worksOf(profileId)).firstWhere((w) => w.id == workId);
      await controller.playWork(work);
      await controller.capture();
      final captures = await db.capturesDao.capturesOf(work.id);
      expect(captures.single.fileIdx, isNull);
    });
  });

  group('finishing an audiobook (the whole playlist, not one file)', () {
    test('emitCompleted after only ONE currentIndex change does not finish '
        'until the fake says the playlist is actually done', () async {
      final work = await seedAudiobook();
      await controller.playAudiobook(work);
      player.emitCurrentIndex(1); // advanced to file 1 — NOT finished yet
      expect((await db.spineDao.workById(work.id))!.finishedEpochDay, isNull);
    });

    test('completedStream (fired once, at the true end) promotes and marks '
        'finished', () async {
      final work = await seedAudiobook();
      await controller.playAudiobook(work);
      player.emitCurrentIndex(1);
      player.emitCompleted();
      await Future<void>.delayed(Duration.zero);

      final updated = await db.spineDao.workById(work.id);
      expect(updated!.finishedEpochDay, isNotNull);
      expect(updated.persistence, 'work');
    });

    test('finishing writes the final PlayerPositions row at the file the '
        'engine actually ended on', () async {
      final work = await seedAudiobook();
      await controller.playAudiobook(work);
      player.emitCurrentIndex(1);
      player.emitPosition(const Duration(minutes: 3));
      player.emitCompleted();
      await Future<void>.delayed(Duration.zero);

      final pos = await db.feedsDao
          .playerPosition(profileId: profileId, workId: work.id);
      expect(pos!.fileIdx, 1);
    });

    test('finishing auto-advances to an audiobook at the head of Up Next '
        'via playAudiobook, not playWork', () async {
      final first = await seedAudiobook(title: 'First');
      final second =
          await seedAudiobook(title: 'Second', paths: const ['/b/0.mp3']);
      await db.queueDao
          .playNext(profileId: profileId, workId: second.id, nowMs: nowMs);

      await controller.playAudiobook(first);
      player.emitCompleted();
      await Future<void>.delayed(Duration.zero);

      expect(controller.current?.id, second.id);
      expect(controller.isAudiobook, isTrue);
      expect(player.loadedFilePaths, ['/b/0.mp3']);
    });
  });

  group('duration lands in AudiobookFiles, never Episodes', () {
    test('durationStream writes AudiobookFiles.durationMs for the current '
        'file', () async {
      final work = await seedAudiobook();
      await controller.playAudiobook(work);
      player.emitCurrentIndex(1);
      player.emitDuration(const Duration(minutes: 45));
      await Future<void>.delayed(Duration.zero);

      final files = await db.audiobooksDao.filesOf(work.id);
      expect(files[1].durationMs, const Duration(minutes: 45).inMilliseconds);
      expect(files[0].durationMs, isNull);
    });
  });

  group('playAudiobookAt: the capture-jump door', () {
    test('jumps straight to the given file and offset', () async {
      final work = await seedAudiobook();
      await controller.playAudiobookAt(work, fileIdx: 1, positionMs: 9000);
      expect(player.loadedInitialIndex, 1);
      expect(player.loadedInitialPosition, const Duration(seconds: 9));
      expect(controller.currentFileIdx, 1);
    });

    test('jumping while a DIFFERENT work is already playing saves its '
        'progress first', () async {
      final other = await seedAudiobook(title: 'Other', paths: const [
        '/o/0.mp3',
      ]);
      await controller.playAudiobook(other);
      player.emitPosition(const Duration(seconds: 3));

      final target = await seedAudiobook(title: 'Target');
      await controller.playAudiobookAt(target, fileIdx: 0, positionMs: 0);

      final otherPos = await db.feedsDao
          .playerPosition(profileId: profileId, workId: other.id);
      expect(otherPos!.tMs, 3000);
    });
  });
}
