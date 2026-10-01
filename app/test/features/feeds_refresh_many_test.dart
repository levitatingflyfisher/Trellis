import 'dart:async';

import 'package:comms_core/comms_core.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/feeds/feed_ingest.dart';
import 'package:trellis/features/feeds/background/feed_check_settings.dart';
import 'package:trellis/features/feeds/feeds_repository.dart';

import '../support/scripted_fetcher.dart';

const _rss = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel>
  <title>A Cast</title>
  <item>
    <title>Episode one</title>
    <link>https://cast.test/one</link>
    <pubDate>Wed, 05 Aug 2026 12:00:00 GMT</pubDate>
  </item>
</channel></rss>
''';

/// A fetcher whose every request waits on its own gate, so a test can see
/// exactly which fetches are in flight at once.
class GatedFetcher {
  final List<(Uri, Completer<FetchResponse>)> open = [];
  int inFlight = 0;
  int maxInFlight = 0;
  final Map<String, int> _hostInFlight = {};
  final Map<String, int> maxPerHost = {};

  late final ScriptedFetcher fetcher = ScriptedFetcher((url, _) {
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    final h = (_hostInFlight[url.host] ?? 0) + 1;
    _hostInFlight[url.host] = h;
    if (h > (maxPerHost[url.host] ?? 0)) maxPerHost[url.host] = h;
    final gate = Completer<FetchResponse>();
    open.add((url, gate));
    return gate.future.whenComplete(() {
      inFlight--;
      _hostInFlight[url.host] = _hostInFlight[url.host]! - 1;
    });
  });

  /// Answers the oldest still-open request.
  void releaseNext([FetchResponse? response]) {
    final (_, gate) = open.removeAt(0);
    gate.complete(response ?? textResponse(_rss));
  }
}

/// The drift in-memory database needs several event-loop turns between
/// fetches; poll a bounded number of them rather than guess one.
Future<void> settleUntil(bool Function() done) async {
  for (var i = 0; i < 500 && !done(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> settle() => settleUntil(() => false);

void main() {
  late AppDatabase db;
  late int profileId;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
  });
  tearDown(() => db.close());

  Future<List<Feed>> seed(List<String> urls) async {
    for (final u in urls) {
      await db.feedsDao.insertFeed(profileId: profileId, url: u);
    }
    return db.feedsDao.feedsOf(profileId);
  }

  group('FeedsRepository.refreshMany', () {
    test('runs up to the cap at once, never more, and starts the next as '
        'each one finishes', () async {
      final gated = GatedFetcher();
      final repo = FeedsRepository(db: db, fetcher: gated.fetcher);
      final feeds =
          await seed([for (var i = 0; i < 7; i++) 'https://h$i.test/feed']);

      final done = repo.refreshMany(feeds, maxConcurrent: 3, maxPerHost: 1);
      await settleUntil(() => gated.open.length == 3);
      await settle();
      expect(gated.open, hasLength(3));

      gated.releaseNext();
      await settleUntil(() => gated.open.length == 3);
      await settle();
      expect(gated.open, hasLength(3), reason: 'exactly one more started');

      while (gated.open.isNotEmpty) {
        gated.releaseNext();
        await settleUntil(() => gated.open.isNotEmpty);
      }
      final outcomes = await done;
      expect(outcomes, hasLength(7));
      expect(gated.maxInFlight, 3);
      expect(outcomes.values.map((o) => o.status).toSet(),
          {RefreshStatus.fresh});
    });

    test('one busy host takes at most its share; other hosts fill the rest '
        'instead of waiting behind it', () async {
      final gated = GatedFetcher();
      final repo = FeedsRepository(db: db, fetcher: gated.fetcher);
      final feeds = await seed([
        for (var i = 0; i < 5; i++) 'https://busy.test/feed$i',
        'https://a.test/feed',
        'https://b.test/feed',
        'https://c.test/feed',
      ]);

      final done = repo.refreshMany(feeds, maxConcurrent: 4, maxPerHost: 2);
      await settleUntil(() => gated.open.length == 4);
      await settle();
      expect(gated.open.map((o) => o.$1.host).toList(),
          ['busy.test', 'busy.test', 'a.test', 'b.test']);

      while (gated.open.isNotEmpty) {
        gated.releaseNext();
        await settleUntil(() => gated.open.isNotEmpty);
      }
      expect(await done, hasLength(8));
      expect(gated.maxPerHost['busy.test'], 2);
      expect(gated.maxInFlight, 4);
    });

    test('a failing feed does not stop the others, and its row keeps the '
        'reason', () async {
      final fetcher = ScriptedFetcher((url, _) {
        if (url.host == 'down.test') return textResponse('', status: 500);
        if (url.host == 'boom.test') throw StateError('socket closed');
        return textResponse(_rss);
      });
      final repo = FeedsRepository(db: db, fetcher: fetcher);
      final feeds = await seed([
        'https://down.test/feed',
        'https://boom.test/feed',
        'https://ok1.test/feed',
        'https://ok2.test/feed',
      ]);

      final outcomes = await repo.refreshMany(feeds, maxConcurrent: 2);

      final byUrl = {
        for (final f in feeds) f.url: outcomes[f.id]!.status,
      };
      expect(byUrl['https://ok1.test/feed'], RefreshStatus.fresh);
      expect(byUrl['https://ok2.test/feed'], RefreshStatus.fresh);
      expect(byUrl['https://down.test/feed'], RefreshStatus.error);
      expect(byUrl['https://boom.test/feed'], RefreshStatus.error);
      final down = (await db.feedsDao.feedsOf(profileId))
          .firstWhere((f) => f.url == 'https://down.test/feed');
      expect(stateOfFeed(down).lastError, isNotNull);
    });

    test('reports progress once per finished feed', () async {
      final repo = FeedsRepository(
          db: db, fetcher: ScriptedFetcher((u, h) => textResponse(_rss)));
      final feeds = await seed(
          ['https://a.test/feed', 'https://b.test/feed', 'https://c.test/f']);
      final seen = <(int, int)>[];

      await repo.refreshMany(feeds,
          onProgress: (done, total) => seen.add((done, total)));

      expect(seen, [(1, 3), (2, 3), (3, 3)]);
    });

    test('an empty list finishes at once', () async {
      final repo = FeedsRepository(
          db: db, fetcher: ScriptedFetcher((u, h) => textResponse(_rss)));
      expect(await repo.refreshMany(const []), isEmpty);
    });
  });

  group('FeedsRepository.followOutlines', () {
    test('inserts each new URL once, trimmed, skipping ones already '
        'followed and repeats within the file', () async {
      await seed(['https://old.test/feed']);
      final repo = FeedsRepository(
          db: db, fetcher: ScriptedFetcher((u, h) => textResponse(_rss)));

      final added = await repo.followOutlines(profileId, const [
        OpmlOutline(url: '  https://new.test/feed ', title: 'New'),
        OpmlOutline(url: 'https://new.test/feed', title: 'Again'),
        OpmlOutline(url: 'https://old.test/feed', title: 'Old'),
        OpmlOutline(url: '   ', title: 'Blank'),
        OpmlOutline(url: 'https://two.test/feed', title: ''),
      ]);

      expect(added.map((f) => (f.url, f.title)),
          [('https://new.test/feed', 'New'), ('https://two.test/feed', '')]);
      expect(await db.feedsDao.feedsOf(profileId), hasLength(3));
    });
  });

  test('refreshAll goes through the same cap', () async {
    final gated = GatedFetcher();
    final repo = FeedsRepository(db: db, fetcher: gated.fetcher);
    await seed([for (var i = 0; i < 6; i++) 'https://h$i.test/feed']);

    final done = repo.refreshAll(profileId);
    await settleUntil(() => gated.open.length == 4);
    await settle();
    expect(gated.open, hasLength(4));

    while (gated.open.isNotEmpty) {
      gated.releaseNext();
      await settleUntil(() => gated.open.isNotEmpty);
    }
    expect(await done, 6, reason: 'one new item from each feed');
    expect(gated.maxInFlight, 4);
  });

  test('asked to stop, what is in flight finishes and nothing new starts',
      () async {
    final gated = GatedFetcher();
    final repo = FeedsRepository(db: db, fetcher: gated.fetcher);
    final feeds =
        await seed([for (var i = 0; i < 6; i++) 'https://h$i.test/feed']);
    var stop = false;

    final done =
        repo.refreshMany(feeds, maxConcurrent: 2, shouldStop: () => stop);
    await settleUntil(() => gated.open.length == 2);
    stop = true;
    gated.releaseNext();
    gated.releaseNext();

    expect(await done, hasLength(2));
    expect(gated.open, isEmpty);
  });

  test('a check that runs to the end is recorded, then afterCheck runs; a '
      'stopped one is neither', () async {
    final gated = GatedFetcher();
    final repo = FeedsRepository(
        db: db,
        fetcher: gated.fetcher,
        now: () => DateTime.fromMillisecondsSinceEpoch(1234));
    var after = 0;
    repo.afterCheck = () async => after++;
    await seed(['https://h0.test/feed']);

    final stopped = repo.refreshAll(profileId, shouldStop: () => true);
    expect(await stopped, 0);
    expect(await readLastChecked(db, profileId), isNull);
    expect(after, 0);

    final done = repo.refreshAll(profileId);
    await settleUntil(() => gated.open.isNotEmpty);
    gated.releaseNext();
    await done;
    expect(await readLastChecked(db, profileId), 1234);
    expect(after, 1);
  });
}
