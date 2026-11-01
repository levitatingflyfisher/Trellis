import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/references/keep_page.dart';

import '../../support/scripted_fetcher.dart';

/// Keeping a cited page (frozen references): one guarded fetch, the page's
/// article kept on the device with its own links, dated, once.
void main() {
  late AppDatabase db;
  late int p;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    p = await db.profilesDao.create('Ada');
  });
  tearDown(() => db.close());

  final words = 'Plain sentences about tides and the moon that run long. ' * 5;
  String page(String title, {String link = ''}) =>
      '<html><head><title>$title</title></head><body><article>'
      '<p>$words $link</p></article></body></html>';

  ScriptedFetcher serving(Map<String, String> pages) =>
      ScriptedFetcher((u, h) {
        final body = pages[u.toString()];
        return body == null
            ? textResponse('gone', status: 404)
            : textResponse(body, headers: {'content-type': 'text/html'});
      });

  test('a page is fetched once, without its fragment, and kept', () async {
    final f = serving({
      'https://tides.test/moon':
          page('Moon tides', link: '<a href="/sun">the sun</a>'),
    });
    final out = await keepLinkedPage(
        db: db,
        fetcher: f,
        profileId: p,
        href: 'https://tides.test/moon#springs',
        epochDay: 20406);
    expect(out, isA<PageKept>());
    final id = (out as PageKept).workId;
    expect(f.calls.single.url.toString(), 'https://tides.test/moon');
    final w = (await db.spineDao.workById(id))!;
    expect((w.kind, w.title, w.sourceUrl, w.firstSeenEpochDay),
        ('frozen', 'Moon tides', 'https://tides.test/moon', 20406));
    expect([for (final l in await db.spineDao.linksOf(id)) l.href],
        ['https://tides.test/sun']);

    final again = await keepLinkedPage(
        db: db,
        fetcher: f,
        profileId: p,
        href: 'https://tides.test/moon',
        epochDay: 20500);
    expect((again as PageKept).workId, id);
    expect(f.calls, hasLength(1), reason: 'a kept page is never fetched again');
  });

  test('a page that cannot be read is a sentence, and nothing is kept',
      () async {
    final out = await keepLinkedPage(
        db: db,
        fetcher: serving({}),
        profileId: p,
        href: 'https://gone.test/x',
        epochDay: 1);
    expect(out, isA<PageNotKept>());
    expect((out as PageNotKept).message, contains('404'));
    expect(await db.spineDao.keptCopyOf(p, 'https://gone.test/x'), isNull);
  });

  test('an address the guard refuses is never fetched', () async {
    final f = serving({});
    for (final href in [
      'http://127.0.0.1/admin',
      'http://192.168.1.1/',
      'file:///etc/hosts',
    ]) {
      final out = await keepLinkedPage(
          db: db, fetcher: f, profileId: p, href: href, epochDay: 1);
      expect(out, isA<PageNotKept>(), reason: href);
    }
    expect(f.calls, isEmpty);
  });

  test('keeping many: each address once, in order, with every outcome',
      () async {
    final f = serving({
      'https://a.test/': page('A'),
      'https://b.test/': page('B'),
    });
    final seen = <(int, int)>[];
    final out = await keepLinkedPages(
        db: db,
        fetcher: f,
        profileId: p,
        hrefs: [
          'https://a.test/#one',
          'https://a.test/#two',
          'https://gone.test/',
          'https://b.test/',
        ],
        epochDay: 1,
        onProgress: (done, total) => seen.add((done, total)));
    expect([for (final c in f.calls) c.url.toString()],
        ['https://a.test/', 'https://gone.test/', 'https://b.test/']);
    expect(out.keys, ['https://a.test/', 'https://gone.test/', 'https://b.test/']);
    expect(out['https://a.test/'], isA<PageKept>());
    expect(out['https://gone.test/'], isA<PageNotKept>());
    expect(seen, [(1, 3), (2, 3), (3, 3)]);
  });

  test('keeping many stops when asked', () async {
    final f = serving({'https://a.test/': page('A'), 'https://b.test/': page('B')});
    var stop = false;
    final out = await keepLinkedPages(
        db: db,
        fetcher: f,
        profileId: p,
        hrefs: ['https://a.test/', 'https://b.test/'],
        epochDay: 1,
        onProgress: (done, total) => stop = true,
        stopped: () => stop);
    expect(out.keys, ['https://a.test/']);
    expect(f.calls, hasLength(1));
  });
}
