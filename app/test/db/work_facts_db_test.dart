import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';

/// Counts selects, so "a list's rows cost the same few queries however
/// many there are" is checked rather than claimed.
class _Selects extends QueryInterceptor {
  int count = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
      QueryExecutor executor, String statement, List<Object?> args) {
    count++;
    return super.runSelect(executor, statement, args);
  }
}

/// The batched lookups behind every list of works: one query per fact
/// for the whole list, never one per row.
void main() {
  late AppDatabase db;
  late _Selects selects;
  late int profileId;

  setUp(() async {
    selects = _Selects();
    db = AppDatabase.forTesting(NativeDatabase.memory().interceptWith(selects));
    profileId = await db.profilesDao.create('Ada');
  });
  tearDown(() => db.close());

  Future<int> work(String title, {String kind = 'note'}) =>
      db.spineDao.insertWork(
          profileId: profileId,
          kind: kind,
          title: title,
          persistence: 'work',
          firstSeenEpochDay: 100);

  test('textSizesOf counts segments and characters per work', () async {
    final a = await work('A');
    final b = await work('B');
    final empty = await work('Empty');
    await db.spineDao.insertSegments(a, [
      (idx: 0, kind: 'prose', text: 'abcd'),
      (idx: 1, kind: 'prose', text: 'ef'),
    ]);
    await db.spineDao
        .insertSegments(b, [(idx: 0, kind: 'prose', text: 'xyz')]);

    final sizes = await db.spineDao.textSizesOf([a, b, empty]);

    expect(sizes[a], (segments: 2, chars: 6));
    expect(sizes[b], (segments: 1, chars: 3));
    expect(sizes.containsKey(empty), isFalse,
        reason: 'a work with no text has no size, not a zero one');
  });

  test('textSizesOf costs the same for 3 works as for 30', () async {
    final ids = [for (var i = 0; i < 30; i++) await work('W$i')];
    for (final id in ids) {
      await db.spineDao
          .insertSegments(id, [(idx: 0, kind: 'prose', text: 'words')]);
    }
    selects.count = 0;
    await db.spineDao.textSizesOf(ids.take(3));
    final few = selects.count;
    selects.count = 0;
    await db.spineDao.textSizesOf(ids);
    expect(selects.count, few);
  });

  test('textSizesOf survives more ids than SQLite takes in one IN list',
      () async {
    final a = await work('A');
    await db.spineDao
        .insertSegments(a, [(idx: 0, kind: 'prose', text: 'abc')]);
    final ids = [for (var i = 0; i < 40000; i++) 100000 + i, a];
    final sizes = await db.spineDao.textSizesOf(ids);
    expect(sizes[a], (segments: 1, chars: 3));
  });

  test('positionsOf maps every work this reader has a place in', () async {
    final a = await work('A');
    final b = await work('B');
    await db.spineDao.savePosition(
        profileId: profileId,
        workId: a,
        segmentIdx: 4,
        wordIdx: 0,
        lastModality: 'read');
    final other = await db.profilesDao.create('Blaise');
    await db.spineDao.savePosition(
        profileId: other,
        workId: b,
        segmentIdx: 2,
        wordIdx: 0,
        lastModality: 'read');

    final positions = await db.spineDao.positionsOf(profileId);
    expect(positions.keys, [a]);
    expect(positions[a]!.segmentIdx, 4);
  });

  test('fileCountsOf counts each audiobook in one query', () async {
    final a = await work('Book A', kind: 'audiobook');
    final b = await work('Book B', kind: 'audiobook');
    await db.audiobooksDao.insertFiles(a, ['1.mp3', '2.mp3', '3.mp3']);
    await db.audiobooksDao.insertFiles(b, ['1.mp3']);
    selects.count = 0;
    final counts = await db.audiobooksDao.fileCountsOf([a, b]);
    expect(counts, {a: 3, b: 1});
    expect(selects.count, 1);
  });

  test('listeningOf carries which file an audiobook reached', () async {
    final a = await work('Book', kind: 'audiobook');
    await db.feedsDao.savePlayerPosition(
        profileId: profileId, workId: a, tMs: 5000, fileIdx: 2);
    final listening = await db.feedsDao.listeningOf(profileId);
    expect(listening.fileIdx[a], 2);
    expect(listening.progressMs[a], 5000);
  });

  test('queueEntriesOf brings each episode and its show in the same query',
      () async {
    final feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://x.test/f', title: 'Night Sky');
    final ep = await work('Aurora', kind: 'episode');
    await db.feedsDao.insertEpisode(
        workId: ep,
        feedId: feedId,
        guid: 'g',
        enclosureUrl: 'https://x.test/a.mp3',
        publishedAtMs: 1);
    final book = await work('A Book', kind: 'book');
    await db.queueDao.playLast(profileId: profileId, workId: ep, nowMs: 1);
    await db.queueDao.playLast(profileId: profileId, workId: book, nowMs: 2);

    selects.count = 0;
    final entries = await db.queueDao.queueEntriesOf(profileId);
    expect(selects.count, 1);
    expect(entries.map((e) => e.work.title), ['Aurora', 'A Book']);
    expect(entries[0].episode?.enclosureUrl, 'https://x.test/a.mp3');
    expect(entries[0].feedTitle, 'Night Sky');
    expect(entries[1].episode, isNull);
    expect(entries[1].feedTitle, isNull);
  });

  test('markUnfinished undoes a finish by hand or by ear', () async {
    final feedId =
        await db.feedsDao.insertFeed(profileId: profileId, url: 'u');
    final id = await work('Field notes', kind: 'article');
    await db.feedsDao.insertEpisode(
        workId: id, feedId: feedId, guid: 'g', publishedAtMs: 1);
    await db.spineDao.markFinished(id, 200);
    await db.feedsDao.setFinished(id, 5);
    await db.spineDao.markUnfinished(id);
    expect((await db.spineDao.workById(id))!.finishedEpochDay, isNull);
    expect((await db.feedsDao.episodeOf(id))!.finishedAtMs, isNull);
  });
}
