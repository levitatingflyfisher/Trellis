import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/feeds/auto_download.dart';
import 'package:trellis/features/feeds/episode_download_coordinator.dart'
    show downloadJobId;

void main() {
  late AppDatabase db;
  late int profileId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Reader');
  });
  tearDown(() => db.close());

  Future<int> feed({int? keep}) async {
    final id = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://cast.test/${DateTime.now().microsecondsSinceEpoch}');
    if (keep != null) {
      await db.feedsDao.updatePlaybackSettings(id, keepLatestAudio: keep);
    }
    return id;
  }

  Future<int> episode(int feedId, int publishedAtMs,
      {bool audio = true}) async {
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: audio ? 'episode' : 'article',
        title: 'Ep $publishedAtMs',
        persistence: 'ephemeron',
        firstSeenEpochDay: 0);
    await db.feedsDao.insertEpisodeIfNew(
        workId: workId,
        feedId: feedId,
        guid: 'g$workId',
        enclosureUrl: audio ? 'https://cast.test/$workId.mp3' : null,
        publishedAtMs: publishedAtMs);
    return workId;
  }

  bool nothingOnDisk(int _, String _) => false;

  // A pass over fakes that behave like the coordinator: a finished
  // download lands on disk and its row goes.
  final onDiskSet = <int>{};
  final started = <int>[];
  final requeued = <int>[];
  var clock = 0;
  Future<bool> pass(
          {Future<void> Function(AutoDownloadPick p)? start,
          bool Function()? shouldStop}) =>
      runAutoDownloadPass(db,
          onDisk: (w, _) => onDiskSet.contains(w),
          queue: (p) => recordQueuedAutoDownload(db, p, ++clock),
          requeue: (w) async => requeued.add(w),
          shouldStop: shouldStop ?? () => false,
          start: (p) async {
            started.add(p.workId);
            if (start != null) {
              await start(p);
            } else {
              onDiskSet.add(p.workId);
              await db.jobsDao.deleteJob(downloadJobId(p.workId));
            }
            return null;
          });
  setUp(() {
    onDiskSet.clear();
    started.clear();
    requeued.clear();
  });

  group('autoDownloadCapFor', () {
    test('three, or fewer when the show keeps fewer', () {
      expect(autoDownloadCapFor(null), 3);
      expect(autoDownloadCapFor(10), 3);
      expect(autoDownloadCapFor(1), 1);
      expect(autoDownloadCapFor(0), 0);
    });
  });

  group('a pass', () {
    test('turning it on fetches nothing from the back catalogue', () async {
      final f = await feed();
      for (var i = 0; i < 5; i++) {
        await episode(f, i);
      }
      await setFeedAutoDownload(db, f, true);

      final plan = await planAutoDownloads(db, onDisk: nothingOnDisk);
      expect(plan.single.picks, isEmpty);
      expect(await autoDownloadsPending(db, onDisk: nothingOnDisk), isFalse);
    });

    test('fetches the newest three that arrived since, newest first',
        () async {
      final f = await feed();
      await episode(f, 1);
      await setFeedAutoDownload(db, f, true);
      final arrived = [
        for (final t in [50, 10, 40, 20, 30]) await episode(f, t),
      ];

      expect(await pass(), isTrue);
      expect(started, [arrived[0], arrived[2], arrived[4]]);
    });

    test('a pass killed mid-download loses no pick and picks none twice',
        () async {
      final f = await feed();
      await setFeedAutoDownload(db, f, true);
      final ep = await episode(f, 1);
      // Killed mid-download, as the system does to a worker.
      await expectLater(pass(start: (_) async => throw 'killed'),
          throwsA('killed'));

      expect([for (final q in await queuedAutoDownloads(db)) q.workId], [ep],
          reason: 'the pick waits as a queued row');
      expect(await autoDownloadsPending(db, onDisk: nothingOnDisk), isTrue);
      started.clear();
      expect(await pass(), isTrue);
      expect(started, [ep], reason: 'carried on, not picked again');
      started.clear();
      expect(await pass(), isTrue);
      expect(started, isEmpty);
    });

    test('skips text, played, evicted, duplicate and already-downloaded '
        'rows', () async {
      final f = await feed();
      await setFeedAutoDownload(db, f, true);
      await episode(f, 1, audio: false);
      final played = await episode(f, 2);
      await db.feedsDao.setFinished(played, 5);
      final evicted = await episode(f, 3);
      await db.feedsDao.setArchived(evicted, 5);
      final dup = await episode(f, 4);
      final other = await episode(f, 0);
      await db.feedsDao
          .setDedup(dup, reason: 'url', canonicalWorkId: other);
      final here = await episode(f, 6);
      final wanted = await episode(f, 7);

      final plan = await planAutoDownloads(db,
          onDisk: (workId, _) => workId == here);
      expect([for (final p in plan.single.picks) p.workId],
          [wanted, other]);
    });

    test('takes no more than the show keeps', () async {
      final f = await feed(keep: 1);
      await setFeedAutoDownload(db, f, true);
      await episode(f, 1);
      final newest = await episode(f, 2);

      final plan = await planAutoDownloads(db, onDisk: nothingOnDisk);
      expect([for (final p in plan.single.picks) p.workId], [newest]);
    });

    test('shows that are not opted in are left alone', () async {
      final f = await feed();
      await episode(f, 1);
      expect(await planAutoDownloads(db, onDisk: nothingOnDisk), isEmpty);
    });

    test('a show opted in without a mark starts from now', () async {
      final f = await feed();
      await db.feedsDao.setAutoDownload(f, true);
      await episode(f, 1);

      expect(await pass(), isTrue);
      expect(started, isEmpty, reason: 'no back catalogue');
      final later = await episode(f, 2);
      await pass();
      expect(started, [later]);
    });

    test('a stop requeues the download it interrupted, starts nothing '
        'more, and asks to be run again', () async {
      final f = await feed();
      await setFeedAutoDownload(db, f, true);
      await episode(f, 1);
      await episode(f, 2);
      var stop = false;
      final done = await pass(
          shouldStop: () => stop, start: (_) async => stop = true);
      expect(done, isFalse);
      expect(started, hasLength(1));
      expect(requeued, started);
      expect(await queuedAutoDownloads(db), hasLength(2));
    });
  });
}
