import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';

/// Latest is a permanent archive (ADR-0019), so its query is paged: an
/// install with every episode an OPML import ever found must not load all
/// of them to paint the first screen.
class _Recorder extends QueryInterceptor {
  final selects = <(String, List<Object?>)>[];

  @override
  Future<List<Map<String, Object?>>> runSelect(
      QueryExecutor executor, String statement, List<Object?> args) {
    selects.add((statement, args));
    return executor.runSelect(statement, args);
  }
}

void main() {
  late AppDatabase db;
  late _Recorder rec;
  late int profileId;
  late int feedId;

  setUp(() async {
    rec = _Recorder();
    db = AppDatabase.forTesting(NativeDatabase.memory().interceptWith(rec));
    profileId = await db.profilesDao.create('Ada');
    feedId = await db.feedsDao.insertFeed(profileId: profileId, url: 'f');
  });
  tearDown(() => db.close());

  Future<int> item(String title,
      {required int publishedAtMs,
      int firstSeenEpochDay = 100,
      bool audio = false,
      int? feed}) async {
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: audio ? 'episode' : 'article',
        title: title,
        persistence: 'ephemeron',
        firstSeenEpochDay: firstSeenEpochDay);
    await db.feedsDao.insertEpisode(
        workId: id,
        feedId: feed ?? feedId,
        guid: title,
        publishedAtMs: publishedAtMs,
        enclosureUrl: audio ? 'https://a/$title.mp3' : null);
    return id;
  }

  RiverCursor cursorOf(RiverEntry e) =>
      (publishedAtMs: e.episode.publishedAtMs, workId: e.work.id);

  List<String> titles(List<RiverEntry> rows) =>
      [for (final r in rows) r.work.title];

  test('order is by publication date, not by when the app first saw it',
      () async {
    // One OPML import stamps every item with the same first-seen day, and
    // a later refresh can see an older item after a newer one.
    await item('oldest', publishedAtMs: 1000, firstSeenEpochDay: 200);
    await item('newest', publishedAtMs: 3000, firstSeenEpochDay: 100);
    await item('middle', publishedAtMs: 2000, firstSeenEpochDay: 300);
    expect(titles(await db.feedsDao.riverItems(profileId)),
        ['newest', 'middle', 'oldest']);
  });

  test('pages chain by keyset with no gap and no repeat, even when new '
      'items land at the top between pages', () async {
    for (var i = 1; i <= 7; i++) {
      await item('i$i', publishedAtMs: i * 10);
    }
    // Two items in the same second: the id settles their order.
    await item('tie', publishedAtMs: 40);

    final first = await db.feedsDao.riverItems(profileId, limit: 3);
    expect(titles(first), ['i7', 'i6', 'i5']);
    await item('arrived', publishedAtMs: 999);
    final second = await db.feedsDao
        .riverItems(profileId, after: cursorOf(first.last), limit: 3);
    expect(titles(second), ['tie', 'i4', 'i3']);
    final third = await db.feedsDao
        .riverItems(profileId, after: cursorOf(second.last), limit: 3);
    expect(titles(third), ['i2', 'i1']);
  });

  test('reloading what is loaded is bounded by the last loaded row',
      () async {
    for (var i = 1; i <= 6; i++) {
      await item('i$i', publishedAtMs: i * 10);
    }
    final first = await db.feedsDao.riverItems(profileId, limit: 3);
    await item('arrived', publishedAtMs: 999);
    final reloaded = await db.feedsDao
        .riverItems(profileId, through: cursorOf(first.last), limit: null);
    expect(titles(reloaded), ['arrived', 'i6', 'i5', 'i4']);
  });

  test('the text and audio chips filter in the query, so a page is full',
      () async {
    for (var i = 1; i <= 4; i++) {
      await item('a$i', publishedAtMs: i * 10, audio: true);
      await item('t$i', publishedAtMs: i * 10 + 1);
    }
    expect(
        titles(await db.feedsDao
            .riverItems(profileId, kind: RiverKind.audio, limit: 3)),
        ['a4', 'a3', 'a2']);
    expect(
        titles(await db.feedsDao
            .riverItems(profileId, kind: RiverKind.text, limit: 3)),
        ['t4', 't3', 't2']);
  });

  test('"everything older" reaches past the loaded page', () async {
    final ids = <int>[];
    for (var i = 1; i <= 5; i++) {
      ids.add(await item('a$i', publishedAtMs: i * 10, audio: true));
    }
    await item('text', publishedAtMs: 15);
    await db.feedsDao.markPlayed(ids[1], 1); // a2
    final older = await db.feedsDao.olderUnplayedAudio(profileId,
        publishedBeforeMs: 50);
    expect([for (final e in older) e.work.title], ['a4', 'a3', 'a1']);
  });

  test('20k items: the first page is LIMITed, walks an index, and never '
      'sorts the archive', () async {
    await db.customStatement('''
      WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n
        WHERE i < 20000)
      INSERT INTO works (profile_id, kind, title, persistence,
          first_seen_epoch_day)
        SELECT $profileId, 'episode', 'w' || i, 'ephemeron', 100 FROM n
    ''');
    await db.customStatement('''
      INSERT INTO episodes (work_id, feed_id, guid, published_at_ms)
        SELECT id, $feedId, 'g' || id, id * 1000 FROM works
    ''');
    Future<List<String>> planOfLast() async {
      final (sql, args) =
          rec.selects.lastWhere((s) => s.$1.contains('published_at_ms'));
      expect(sql, contains('LIMIT'));
      return [
        for (final r in await db
            .customSelect('EXPLAIN QUERY PLAN $sql',
                variables: [for (final a in args) Variable(a)])
            .get())
          r.read<String>('detail')
      ];
    }

    final page = await db.feedsDao.riverItems(profileId);
    expect(page, hasLength(riverPageSize));
    expect(page.first.work.title, 'w20000');
    var plan = await planOfLast();
    expect(plan.where((d) => d.contains('TEMP B-TREE')), isEmpty,
        reason: plan.join('\n'));
    expect(plan.join('\n'), contains('idx_episodes_published'));

    final next = await db.feedsDao
        .riverItems(profileId, after: cursorOf(page.last));
    expect(next.first.work.title, 'w${20000 - riverPageSize}');
    plan = await planOfLast();
    expect(plan.where((d) => d.contains('TEMP B-TREE')), isEmpty,
        reason: plan.join('\n'));
  });
}
