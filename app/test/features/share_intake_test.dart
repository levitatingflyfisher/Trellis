import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/intake/audiobook_import.dart';
import 'package:trellis/features/intake/share_intake.dart';
import 'package:trellis/features/search/search_store.dart';

import '../support/scripted_fetcher.dart';

const _essay =
    '<html><head><title>On hedges</title>'
    '<link rel="alternate" type="application/rss+xml" href="/feed.xml">'
    '</head><body><article><h1>On hedges</h1><p>'
    'A laid hedge is cut most of the way through at the base and bent '
    'over, so it grows thick from below. It takes a winter, a billhook '
    'and patience, and it lasts for decades if it is laid again when it '
    'grows up and out of reach of the cattle it was meant to keep in.'
    '</p></article></body></html>';

const _feed =
    '<?xml version="1.0"?><rss version="2.0"><channel>'
    '<title>Field Notes</title></channel></rss>';

/// The share sheet's router: what was shared decides where it goes, and
/// the common case (a link, a bot's report) goes there without a prompt.
void main() {
  late AppDatabase db;
  late int profileId;
  late int nowMs;
  late Map<String, String> pages;
  late ScriptedFetcher fetcher;
  late List<String> discarded;
  late Map<String, String> files;
  late List<String> books;
  late List<String> audioCopies;
  late Map<String, int> sizes;
  late Set<String> failingBooks;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    nowMs = DateTime(2026, 10, 25, 9).millisecondsSinceEpoch;
    pages = {};
    fetcher = ScriptedFetcher((url, _) {
      final body = pages[url.toString()];
      if (body == null) throw const SocketException('offline');
      return textResponse(
        body,
        headers: {'content-type': 'text/html; charset=utf-8'},
      );
    });
    discarded = [];
    files = {};
    books = [];
    audioCopies = [];
    sizes = {};
    failingBooks = {};
  });
  tearDown(() => db.close());

  ShareIntake intake() => ShareIntake(
    db: db,
    profileId: profileId,
    fetcher: fetcher,
    now: () => DateTime.fromMillisecondsSinceEpoch(nowMs),
    readText: (path) async => files[path]!,
    sizeOf: (path) => sizes[path] ?? files[path]?.length ?? 0,
    discard: discarded.add,
    importBook: (path, name) async {
      if (failingBooks.contains(name)) throw const FormatException('bad');
      books.add(name);
      return db.spineDao.insertWork(
        profileId: profileId,
        kind: 'book',
        title: name,
        persistence: 'work',
        firstSeenEpochDay: 1,
      );
    },
    audiobooks: AudiobookImportRepository(
      db: db,
      destinationFor: (w, i, name) => File('/fake/$w/$i-$name'),
      readable: (_) => true,
      copyFile: (src, dest) => audioCopies.add(src),
    ),
  );

  Future<RiverEntry> onlyLatest() async =>
      (await db.feedsDao.riverItems(profileId)).single;

  group('sharedTitle', () {
    test('the first line, trimmed and capped; a date when there is none', () {
      expect(
        sharedTitle('  Muse daily: rates  \nbody', nowMs),
        'Muse daily: rates',
      );
      expect(sharedTitle('\n\n# Weekly digest\nmore', nowMs), 'Weekly digest');
      final long = sharedTitle('${'word ' * 40}\nbody', nowMs);
      expect(long.length, lessThanOrEqualTo(80));
      expect(long, endsWith('…'));
      expect(sharedTitle('', nowMs), 'Shared 25 Oct');
      expect(sharedTitle('#\nbody', nowMs), 'Shared 25 Oct');
    });
  });

  group('singleUrlIn', () {
    test('only a whole share that is one web address is a link', () {
      expect(
        singleUrlIn('  https://example.org/a  '),
        Uri.parse('https://example.org/a'),
      );
      expect(singleUrlIn('Read this https://example.org/a'), isNull);
      expect(singleUrlIn('https://a.example https://b.example'), isNull);
      expect(singleUrlIn('ftp://example.org/a'), isNull);
      expect(singleUrlIn('just words'), isNull);
    });
  });

  group('text', () {
    test('a bot’s report lands in Latest as a text under Shared, named by '
        'the app, and is searchable', () async {
      const report =
          'Muse daily: three things\n\nRates held. The '
          'lighthouse keepers met. See https://example.org/a for more.';
      final out = await intake().take(
        const SharedPayload(text: report, sourceApp: 'Muse'),
      );
      expect(out, isA<ShareSaved>());
      final saved = out as ShareSaved;
      expect(saved.inLatest, isTrue);
      expect(saved.existing, isFalse);
      final row = await onlyLatest();
      expect(row.work.id, saved.workId);
      expect(row.work.title, 'Muse daily: three things');
      expect(row.work.kind, 'note');
      expect(row.feedTitle, 'Muse');
      expect(row.episode.publishedAtMs, nowMs);
      expect(fetcher.calls, isEmpty, reason: 'a report with links is text');
      final found = await SearchStore(db).search(profileId, 'lighthouse');
      expect([for (final i in found.items) i.work.id], [saved.workId]);
    });

    test('without an app name the row says Shared', () async {
      await intake().take(const SharedPayload(text: 'A note to self'));
      expect((await onlyLatest()).feedTitle, 'Shared');
    });

    test(
      'the same text within a minute is the same share; later it is new',
      () async {
        final first =
            await intake().take(const SharedPayload(text: 'Same'))
                as ShareSaved;
        nowMs += 30 * 1000;
        final again =
            await intake().take(const SharedPayload(text: 'Same'))
                as ShareSaved;
        expect(again.workId, first.workId);
        expect(again.existing, isTrue);
        nowMs += 2 * 60 * 1000;
        final later =
            await intake().take(const SharedPayload(text: 'Same'))
                as ShareSaved;
        expect(later.workId, isNot(first.workId));
        expect(await db.feedsDao.riverItems(profileId), hasLength(2));
      },
    );

    test('nothing but blank space is refused', () async {
      expect(
        await intake().take(const SharedPayload(text: '  \n ')),
        isA<ShareRefused>(),
      );
    });
  });

  group('links', () {
    const essayUrl = 'https://blog.example/2026/hedges';

    test('a link is saved at once, before any fetch, then the page fills the '
        'same row in place', () async {
      pages[essayUrl] = _essay;
      final saved = await intake().take(const SharedPayload(
          text: '$essayUrl#top', sourceApp: 'Chrome')) as ShareSaved;
      expect(fetcher.calls, isEmpty, reason: 'saved before the network');
      expect(saved.inLatest, isTrue);
      expect(saved.pageToFetch.toString(), essayUrl);
      final before = await onlyLatest();
      expect(before.work.id, saved.workId);
      expect(before.work.sourceUrl, essayUrl);

      final up = await intake().fetchPageFor(saved);
      expect(up, isA<ShareUpgraded>());
      expect(fetcher.calls.single.url.toString(), essayUrl);
      final row = await onlyLatest();
      expect(row.work.id, saved.workId, reason: 'the same row, upgraded');
      expect(row.work.kind, 'article');
      expect(row.work.title, 'On hedges');
      expect(row.feedTitle, 'Chrome');
      expect(await db.spineDao.segmentCount(row.work.id), greaterThan(0));
      final found = await SearchStore(db).search(profileId, 'billhook');
      expect([for (final i in found.items) i.work.id], [saved.workId]);
    });

    test('trackers are stripped before the duplicate check and the fetch',
        () async {
      pages[essayUrl] = _essay;
      final first = await intake().take(const SharedPayload(
          text: '$essayUrl?utm_source=x&fbclid=y')) as ShareSaved;
      expect(first.pageToFetch.toString(), essayUrl);
      await intake().fetchPageFor(first);
      final again = await intake().take(
              const SharedPayload(text: '$essayUrl?gclid=z')) as ShareSaved;
      expect(again.workId, first.workId);
      expect(again.existing, isTrue);
      expect(again.pageToFetch, isNull, reason: 'already read');
      expect(fetcher.calls, hasLength(1));
      expect(await db.feedsDao.riverItems(profileId), hasLength(1));
    });

    test('a link that couldn’t be read is fetched again on a re-share, and '
        'on open', () async {
      final saved = await intake().take(const SharedPayload(
          text: 'https://gone.example/post', subject: 'A lost post'))
          as ShareSaved;
      final failed = await intake().fetchPageFor(saved);
      expect(failed, isA<ShareRefused>());
      final row = await onlyLatest();
      expect(row.work.title, 'A lost post');
      expect(row.work.sourceUrl, 'https://gone.example/post');

      // Back online: sharing it again re-reads it into the same row.
      pages['https://gone.example/post'] = _essay;
      final again = await intake().take(
              const SharedPayload(text: 'https://gone.example/post'))
          as ShareSaved;
      expect(again.workId, saved.workId);
      expect(again.existing, isTrue);
      expect(again.pageToFetch, isNotNull);
      expect(await intake().fetchPageFor(again), isA<ShareUpgraded>());
      expect((await onlyLatest()).work.title, 'On hedges');
      expect(await db.feedsDao.riverItems(profileId), hasLength(1));
    });

    test('opening a link-only row re-reads it; a read row is left alone',
        () async {
      final saved = await intake().take(
          const SharedPayload(text: 'https://gone.example/a')) as ShareSaved;
      await intake().fetchPageFor(saved);
      pages['https://gone.example/a'] = _essay;
      expect(await intake().refetchIfLinkOnly(saved.workId),
          isA<ShareUpgraded>());
      expect(await intake().refetchIfLinkOnly(saved.workId), isNull);
      expect(fetcher.calls, hasLength(2));
    });

    test('a profile link offers to subscribe, with no fetch and no row',
        () async {
      final offer = await intake().take(const SharedPayload(
          text: 'https://bsky.app/profile/alice.example.com')) as ShareOffersFeed;
      expect(offer.feedUrl, 'https://bsky.app/profile/alice.example.com/rss');
      expect(offer.name, '@alice.example.com');
      expect(offer.linkWorkId, isNull);
      expect(fetcher.calls, isEmpty);
      expect(await db.feedsDao.riverItems(profileId), isEmpty);

      // "Save this page" makes the row, then reads the page without asking
      // about the feed again.
      final saved = await intake().savePage(offer) as ShareSaved;
      expect(saved.pageToFetch, isNotNull);
      expect(saved.askAboutFeeds, isFalse);
      expect(await db.feedsDao.riverItems(profileId), hasLength(1));
    });

    test('an address that serves a feed offers it once fetched, naming the '
        'feed, and following it drops the link row', () async {
      pages['https://notes.example/latest'] = _feed;
      final saved = await intake().take(
          const SharedPayload(text: 'https://notes.example/latest'))
          as ShareSaved;
      final offer = await intake().fetchPageFor(saved) as ShareOffersFeed;
      expect(offer.feedUrl, 'https://notes.example/latest');
      expect(offer.name, 'Field Notes');
      expect(offer.linkWorkId, saved.workId);
      await intake().dropLink(offer);
      expect(await db.feedsDao.riverItems(profileId), isEmpty);
    });

    test('a front page that advertises a feed offers it under the site’s '
        'name; saving the page upgrades the row from the page in hand',
        () async {
      pages['https://blog.example/'] = _essay.replaceFirst('<title>',
          '<meta property="og:site_name" content="Hedgerow Notes"><title>');
      final saved = await intake().take(
          const SharedPayload(text: 'https://blog.example/')) as ShareSaved;
      final offer = await intake().fetchPageFor(saved) as ShareOffersFeed;
      expect(offer.feedUrl, 'https://blog.example/feed.xml');
      expect(offer.name, 'Hedgerow Notes');
      final kept = await intake().savePage(offer) as ShareSaved;
      expect(kept.workId, saved.workId);
      expect(kept.pageToFetch, isNull);
      expect((await onlyLatest()).work.kind, 'article');
      expect(fetcher.calls, hasLength(1));
    });

    test('a post on a site that advertises its feed simply saves', () async {
      pages[essayUrl] = _essay;
      final saved = await intake().take(
          const SharedPayload(text: essayUrl)) as ShareSaved;
      expect(await intake().fetchPageFor(saved), isA<ShareUpgraded>());
    });

    test('an address the guard refuses is refused before any fetch',
        () async {
      final out = await intake().take(
        const SharedPayload(text: 'http://127.0.0.1/admin'),
      );
      expect(out, isA<ShareRefused>());
      expect(fetcher.calls, isEmpty);
      expect(await db.feedsDao.riverItems(profileId), isEmpty);
    });
  });

  group('files', () {
    test('a markdown file lands in Latest as a text and its copy is removed',
        () async {
      files['/cache/r.md'] = '# Dots weekly\n\nAll quiet on the hill.';
      final out = await intake().take(const SharedPayload(files: [
        SharedFile(path: '/cache/r.md', name: 'r.md', mimeType: 'text/markdown'),
      ], sourceApp: 'Dots'));
      final saved = out as ShareSaved;
      expect(saved.inLatest, isTrue);
      final row = await onlyLatest();
      expect(row.work.title, 'Dots weekly');
      expect(row.feedTitle, 'Dots');
      expect(discarded, ['/cache/r.md']);
    });

    test('an HTML file is extracted like a page', () async {
      files['/cache/p.html'] = _essay;
      final saved = await intake().take(const SharedPayload(files: [
        SharedFile(path: '/cache/p.html', name: 'p.html', mimeType: 'text/html'),
      ])) as ShareSaved;
      expect((await db.spineDao.workById(saved.workId))!.title, 'On hedges');
    });

    test('a text file past the cap is not read into memory', () async {
      files['/cache/huge.txt'] = 'x';
      sizes['/cache/huge.txt'] = maxSharedTextBytes + 1;
      final out = await intake().take(const SharedPayload(files: [
        SharedFile(path: '/cache/huge.txt', name: 'huge.txt', mimeType: 'text/plain'),
      ]));
      expect(out, isA<ShareRefused>());
      expect(discarded, ['/cache/huge.txt']);
    });

    test('an EPUB goes through the book import, into the Library', () async {
      final saved = await intake().take(const SharedPayload(files: [
        SharedFile(
            path: '/cache/b.epub', name: 'b.epub', mimeType: 'application/epub+zip'),
      ])) as ShareSaved;
      expect(books, ['b.epub']);
      expect(saved.inLatest, isFalse);
      expect(discarded, ['/cache/b.epub']);
    });

    test('one file failing doesn’t lose the others', () async {
      failingBooks.add('bad.epub');
      files['/cache/r.md'] = 'A note';
      final saved = await intake().take(const SharedPayload(files: [
        SharedFile(path: '/cache/bad.epub', name: 'bad.epub', mimeType: 'application/epub+zip'),
        SharedFile(path: '/cache/r.md', name: 'r.md', mimeType: 'text/markdown'),
      ])) as ShareSaved;
      expect(saved.count, 1);
      expect(saved.failed, 1);
      expect((await onlyLatest()).work.title, 'A note');
      expect(discarded, containsAll(['/cache/bad.epub', '/cache/r.md']));
    });

    test('audio files go through the audiobook import as one work, named in '
        'any script', () async {
      final saved = await intake().take(const SharedPayload(files: [
        SharedFile(path: '/cache/02.mp3', name: 'Глава 02.mp3', mimeType: 'audio/mpeg'),
        SharedFile(path: '/cache/01.mp3', name: 'Глава 01.mp3', mimeType: 'audio/mpeg'),
      ])) as ShareSaved;
      expect(saved.inLatest, isFalse);
      final work = (await db.spineDao.workById(saved.workId))!;
      expect(work.kind, 'audiobook');
      expect(work.title, 'Глава 01');
      expect(audioCopies, ['/cache/01.mp3', '/cache/02.mp3']);
      expect(discarded, containsAll(['/cache/01.mp3', '/cache/02.mp3']));
    });

    test('a kind Trellis can’t open is refused and its copy removed',
        () async {
      final out = await intake().take(const SharedPayload(files: [
        SharedFile(path: '/cache/x.pdf', name: 'x.pdf', mimeType: 'application/pdf'),
      ]));
      expect(out, isA<ShareRefused>());
      expect(discarded, ['/cache/x.pdf']);
    });

    test('a file the platform refused says why', () async {
      final big = await intake().take(const SharedPayload(refused: [
        SharedRefusal(
            name: 'book.m4b',
            reason: 'tooBig',
            bytes: 250 * 1024 * 1024,
            limit: 200 * 1024 * 1024),
      ]));
      expect((big as ShareRefused).message,
          'Too big to share (250 MB; the limit is 200 MB).');
      final unknown = await intake().take(const SharedPayload(refused: [
        SharedRefusal(name: 'b.m4b', reason: 'tooBig', limit: 200 * 1024 * 1024),
      ]));
      expect((unknown as ShareRefused).message,
          'Too big to share (the limit is 200 MB).');
      final stalled = await intake().take(const SharedPayload(
          refused: [SharedRefusal(name: 'a.mp3', reason: 'stalled')]));
      expect((stalled as ShareRefused).message,
          'The file stopped arriving, so it wasn’t saved.');
      final kind = await intake().take(const SharedPayload(
          refused: [SharedRefusal(name: 'x.pdf', reason: 'unsupported')]));
      expect((kind as ShareRefused).message,
          'Trellis can’t open that kind of file.');
    });

    test('a refused file beside a saved one counts as not opened', () async {
      files['/cache/r.md'] = 'Kept note';
      final saved = await intake().take(const SharedPayload(
        files: [
          SharedFile(path: '/cache/r.md', name: 'r.md', mimeType: 'text/markdown'),
        ],
        refused: [SharedRefusal(name: 'big.mp3', reason: 'tooBig')],
      )) as ShareSaved;
      expect(saved.failed, 1);
    });

    test('a refusal survives the trip through the waiting list', () {
      const p = SharedPayload(refused: [
        SharedRefusal(name: 'b.m4b', reason: 'tooBig', bytes: 5, limit: 4),
      ]);
      final back = SharedPayload.fromJson(p.toJson()).refused.single;
      expect(back.name, 'b.m4b');
      expect(back.reason, 'tooBig');
      expect(back.bytes, 5);
      expect(back.limit, 4);
    });

    test('text that came with a file it can’t open is still saved', () async {
      final out = await intake().take(const SharedPayload(
        text: 'A caption worth keeping',
        files: [
          SharedFile(path: '/cache/p.jpg', name: 'p.jpg', mimeType: 'image/jpeg'),
        ],
      ));
      expect(out, isA<ShareSaved>());
      expect((await onlyLatest()).work.title, 'A caption worth keeping');
    });
  });
}
