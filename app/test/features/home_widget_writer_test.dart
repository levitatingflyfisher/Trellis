import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/home_widget/home_widget_host.dart';
import 'package:trellis/features/home_widget/widget_snapshot.dart';
import 'package:trellis/features/home_widget/widget_snapshot_writer.dart';
import 'package:trellis/features/player/player_controller.dart';

import '../support/fake_player.dart';

/// The home-screen widget (1.5.5) reads a small snapshot Dart writes: what
/// was last played, and what was last read. These pin which fields are
/// written and when: at once on a track or play/pause change, but the
/// position only about every 30 s while playing, never per tick.
class RecordingHost extends HomeWidgetHost {
  final List<WidgetSnapshot> pushed = [];
  @override
  bool get available => true;
  @override
  Future<void> push(WidgetSnapshot snapshot) async => pushed.add(snapshot);
}

void main() {
  late AppDatabase db;
  late FakeEpisodePlayer player;
  late PlayerController controller;
  late RecordingHost host;
  late int profileId;
  late int feedId;
  late DateTime clock;
  late Directory artDir;
  WidgetSnapshotWriter? writer;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    player = FakeEpisodePlayer();
    host = RecordingHost();
    profileId = await db.profilesDao.create('Ada');
    feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://cast.test/feed', title: 'The Show');
    clock = DateTime.utc(2026, 10, 25, 9);
    controller = PlayerController(
        db: db,
        profileId: profileId,
        createPlayer: () => player,
        now: () => clock);
    artDir = Directory.systemTemp.createTempSync('widget_art');
  });

  tearDown(() async {
    writer?.dispose();
    writer = null;
    controller.dispose();
    await db.close();
    artDir.deleteSync(recursive: true);
  });

  WidgetSnapshotWriter makeWriter({Duration readingEvery = Duration.zero}) =>
      writer = WidgetSnapshotWriter(
        db: db,
        profileId: profileId,
        player: controller,
        host: host,
        now: () => clock,
        artworkFileFor: (id) => File('${artDir.path}/$id.jpg'),
        readingEvery: readingEvery,
      );

  Future<Work> seedEpisode(String title) async {
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: title,
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/$title.mp3');
    await db.feedsDao.insertEpisode(
        workId: id,
        feedId: feedId,
        guid: 'g-$title',
        enclosureUrl: 'https://cast.test/$title.mp3',
        publishedAtMs: 1000);
    return (await db.spineDao.workById(id))!;
  }

  Future<Work> seedText(String title, {int segments = 10}) async {
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'article',
        title: title,
        persistence: 'kept',
        firstSeenEpochDay: 100);
    await db.spineDao.insertSegments(id, [
      for (var i = 0; i < segments; i++)
        (idx: i, kind: 'prose', text: 'Sentence $i.'),
    ]);
    return (await db.spineDao.workById(id))!;
  }

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('empty: nothing played and nothing read writes an empty snapshot',
      () async {
    await makeWriter().start();
    await settle();
    expect(host.pushed, isNotEmpty);
    final s = host.pushed.last;
    expect(s.audio, isNull);
    expect(s.reading, isNull);
    expect(s.profileId, profileId);
    expect(s.toJson()['audio'], isNull);
    expect(s.toJson()['reading'], isNull);
  });

  test('playing writes the title, show, art, position and playing',
      () async {
    File('${artDir.path}/$feedId.jpg').writeAsBytesSync([1, 2, 3]);
    final ep = await seedEpisode('Ep1');
    await makeWriter().start();
    await controller.playWork(ep);
    player.emitDuration(const Duration(minutes: 40));
    await settle();
    final a = host.pushed.last.audio!;
    expect(a.workId, ep.id);
    expect(a.title, 'Ep1');
    expect(a.show, 'The Show');
    expect(a.artPath, '${artDir.path}/$feedId.jpg');
    expect(a.playing, isTrue);
    expect(a.loaded, isTrue);
    expect(a.durationMs, const Duration(minutes: 40).inMilliseconds);
  });

  test('art is a local file or nothing, never a URL', () async {
    final ep = await seedEpisode('Ep1');
    await makeWriter().start();
    await controller.playWork(ep);
    await settle();
    expect(host.pushed.last.audio!.artPath, isNull,
        reason: 'no file on disk, so no art; the widget never fetches');
  });

  test('pause writes at once', () async {
    final ep = await seedEpisode('Ep1');
    await makeWriter().start();
    await controller.playWork(ep);
    await settle();
    final before = host.pushed.length;
    await controller.toggle();
    await settle();
    expect(host.pushed.length, greaterThan(before));
    expect(host.pushed.last.audio!.playing, isFalse);
  });

  test('a track change writes at once', () async {
    final one = await seedEpisode('Ep1');
    final two = await seedEpisode('Ep2');
    await makeWriter().start();
    await controller.playWork(one);
    await settle();
    await controller.playWork(two);
    await settle();
    expect(host.pushed.last.audio!.title, 'Ep2');
  });

  test('a ten-minute play writes at most about 20 position updates',
      () async {
    final ep = await seedEpisode('Ep1');
    await makeWriter().start();
    await controller.playWork(ep);
    player.emitDuration(const Duration(hours: 1));
    await settle();
    final before = host.pushed.length;
    // just_audio ticks about five times a second.
    for (var ms = 0; ms <= 10 * 60 * 1000; ms += 200) {
      clock = clock.add(const Duration(milliseconds: 200));
      player.emitPosition(Duration(milliseconds: ms));
    }
    await settle();
    final writes = host.pushed.length - before;
    expect(writes, inInclusiveRange(15, 21));
    expect(host.pushed.last.audio!.positionMs,
        greaterThanOrEqualTo(9 * 60 * 1000));
  });

  test('last played survives a restart, shown paused at its place',
      () async {
    final ep = await seedEpisode('Ep1');
    await db.profilesDao.recordLastPlayed(profileId, ep.id);
    await db.feedsDao.savePlayerPosition(
        profileId: profileId, workId: ep.id, tMs: 61000);
    await controller.rehydrateLastPlayed();
    await makeWriter().start();
    await settle();
    final a = host.pushed.last.audio!;
    expect(a.title, 'Ep1');
    expect(a.playing, isFalse);
    expect(a.positionMs, 61000);
    expect(a.loaded, isFalse,
        reason: 'not loaded yet: a widget Play must open the app to load it');
  });

  test('a closed bar keeps its card, no longer loaded', () async {
    final ep = await seedEpisode('Ep1');
    await makeWriter().start();
    await controller.playWork(ep);
    await settle();
    await controller.stop();
    await settle();
    final a = host.pushed.last.audio!;
    expect(a.title, 'Ep1');
    expect(a.playing, isFalse);
    expect(a.loaded, isFalse);
  });

  test('continue reading: the last-read text, with its progress', () async {
    final older = await seedText('Older');
    final newer = await seedText('Newer', segments: 4);
    await db.spineDao.savePosition(
        profileId: profileId,
        workId: older.id,
        segmentIdx: 5,
        wordIdx: 0,
        lastModality: 'read');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await db.spineDao.savePosition(
        profileId: profileId,
        workId: newer.id,
        segmentIdx: 1,
        wordIdx: 0,
        lastModality: 'read');
    await makeWriter().start();
    await settle();
    final r = host.pushed.last.reading!;
    expect(r.workId, newer.id);
    expect(r.title, 'Newer');
    expect(r.progress, closeTo(0.25, 1e-9));
  });

  test('a listened episode is never the work to continue reading',
      () async {
    final text = await seedText('A text');
    final ep = await seedEpisode('Ep1');
    await db.spineDao.savePosition(
        profileId: profileId,
        workId: text.id,
        segmentIdx: 2,
        wordIdx: 0,
        lastModality: 'read');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await db.spineDao.savePosition(
        profileId: profileId,
        workId: ep.id,
        segmentIdx: 0,
        wordIdx: 0,
        lastModality: 'listen');
    await makeWriter().start();
    await settle();
    expect(host.pushed.last.reading!.title, 'A text');
  });

  test('reading progress updates the widget, throttled', () async {
    final text = await seedText('Book', segments: 100);
    await makeWriter(readingEvery: const Duration(milliseconds: 300)).start();
    await settle();
    final before = host.pushed.length;
    for (var i = 0; i < 30; i++) {
      await db.spineDao.savePosition(
          profileId: profileId,
          workId: text.id,
          segmentIdx: i,
          wordIdx: 0,
          lastModality: 'read');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await settle();
    final writes = host.pushed.length - before;
    expect(writes, inInclusiveRange(1, 4));
    expect(host.pushed.last.reading!.progress, closeTo(0.29, 1e-9),
        reason: 'the last change still lands');
  });

  test('the JSON the Kotlin provider reads', () {
    const s = WidgetSnapshot(
      profileId: 3,
      audio: AudioCard(
          workId: 7,
          title: 'T',
          show: 'S',
          artPath: '/a.jpg',
          positionMs: 1000,
          durationMs: 4000,
          playing: true,
          loaded: true),
      reading: ReadingCard(workId: 9, title: 'R', progress: 0.5),
    );
    expect(s.toJson(), {
      'v': 1,
      'profileId': 3,
      'audio': {
        'workId': 7,
        'title': 'T',
        'show': 'S',
        'art': '/a.jpg',
        'positionMs': 1000,
        'durationMs': 4000,
        'playing': true,
        'loaded': true,
      },
      'reading': {'workId': 9, 'title': 'R', 'progress': 0.5},
    });
  });
}
