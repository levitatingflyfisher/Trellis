import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:trellis/db/database.dart';
import 'package:trellis/features/search/history_days.dart';
import 'package:trellis/features/search/search_store.dart';

import '../support/schema_strip.dart';

/// History and search (ADR-0016 section 4): the FTS index follows its
/// rows through insert, rename and delete; transcript hits carry a
/// snippet and the time to seek to; history is most recent first.
void main() {
  late AppDatabase db;
  late SearchStore store;
  late int profileId;
  late int feedId;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = SearchStore(db);
    profileId = await db.profilesDao.create('Ada');
    feedId = await db.feedsDao.insertFeed(
        profileId: profileId,
        url: 'https://cast.test/f',
        title: 'Night Sky Hour');
  });
  tearDown(() => db.close());

  Future<int> episode(String title, {int publishedAtMs = 1, int? feed}) async {
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: title,
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/$title.mp3');
    await db.feedsDao.insertEpisode(
        workId: id,
        feedId: feed ?? feedId,
        guid: title,
        enclosureUrl: 'https://cast.test/$title.mp3',
        publishedAtMs: publishedAtMs);
    return id;
  }

  Future<int> book(String title, {int? profile}) => db.spineDao.insertWork(
      profileId: profile ?? profileId,
      kind: 'book',
      title: title,
      persistence: 'work',
      firstSeenEpochDay: 100);

  Future<void> transcribe(int workId, List<String> sentences) async {
    await db.spineDao.insertSegments(workId, [
      for (final (i, s) in sentences.indexed) (idx: i, kind: 'prose', text: s)
    ]);
    await db.spineDao.insertAlignments(workId, [
      for (var i = 0; i < sentences.length; i++)
        (segmentIdx: i, tStartMs: 60000 * i + 5000, tEndMs: 60000 * (i + 1))
    ]);
  }

  Iterable<String> titles(SearchResults r) => r.items.map((i) => i.work.title);

  group('the query', () {
    test('quotes every term and prefixes every one', () {
      expect(SearchStore.matchQuery('aurora sea'), '"aurora"* "sea"*');
    });

    test('a contraction stays one phrase, either apostrophe', () {
      expect(SearchStore.matchQuery("it's"), '"it s"');
      expect(SearchStore.matchQuery('it’s time'), '"it s" "time"*');
      // Half typed: the apostrophe has nothing after it yet.
      expect(SearchStore.matchQuery("don'"), '"don"*');
    });

    test('hostile input becomes plain terms', () {
      expect(SearchStore.matchQuery('c++ don\'t "x NEAR foo:'),
          '"c"* "don t" "x"* "NEAR"* "foo"*');
      expect(SearchStore.matchQuery('  ::  '), isNull);
    });

    test('hostile input never throws from the database', () async {
      await episode('Aurora season');
      for (final q in ['"', 'NEAR(', 'foo:', '*', 'AND OR NOT', '(((']) {
        await store.search(profileId, q);
      }
    });
  });

  group('shows', () {
    for (final like in [false, true]) {
      test('a followed show is found by its name, even with no items '
          '(${like ? 'LIKE' : 'index'})', () async {
        final s = SearchStore(db, forceLike: like);
        final bam = await db.feedsDao.insertFeed(
            profileId: profileId,
            url: 'https://money.test/rss',
            title: 'Hedgerow Ledger');
        final other = await db.profilesDao.create('Grace');
        await db.feedsDao.insertFeed(
            profileId: other, url: 'https://b.test/f', title: 'Hedgerow Ledger');
        final r = await s.search(profileId, 'hedge ledger');
        expect(r.shows.map((f) => f.id), [bam]);
        expect(r.items, isEmpty);
        expect(r.isEmpty, isFalse);
        expect((await s.search(profileId, 'ledger')).shows.single.id, bam);
        expect((await s.search(profileId, 'zebra')).shows, isEmpty);
      });
    }

    test('a common word lists the first shows in shelf order, not any '
        'twenty', () async {
      // Inserted backwards, so the table's own order is the wrong one.
      for (var i = 29; i >= 0; i--) {
        await db.feedsDao.insertFeed(
            profileId: profileId,
            url: 'https://p$i.test',
            title: 'Podcast ${i.toString().padLeft(2, '0')}');
      }
      final r = await SearchStore(db, pageSize: 20).search(profileId, 'podcast');
      expect(r.showSection.count, 30);
      expect(r.shows.map((f) => f.title),
          [for (var i = 0; i < 20; i++) 'Podcast ${i.toString().padLeft(2, '0')}']);
    });

    test('shows come in shelf order, not ranked', () async {
      await db.feedsDao.insertFeed(
          profileId: profileId, url: 'https://z.test', title: 'Sky Zebra');
      await db.feedsDao.insertFeed(
          profileId: profileId, url: 'https://a.test', title: 'The Sky Atlas');
      expect([for (final f in (await store.search(profileId, 'sky')).shows) f.title],
          ['Night Sky Hour', 'The Sky Atlas', 'Sky Zebra']);
    });
  });

  group('show notes (1.5.4)', () {
    test('a word only in an episode\'s notes finds the episode, and its '
        'markup never matches', () async {
      final id = await episode('Episode 12');
      await db.feedsDao.fillNotes(id,
          html: '<p>Guest: <a href="https://x.test">Vera Rubin</a></p>',
          plain: 'Guest: Vera Rubin');
      expect(titles(await store.search(profileId, 'rubin')), ['Episode 12']);
      expect(titles(await store.search(profileId, 'href')), isEmpty);
      await db.spineDao.deleteWork(id);
      expect(titles(await store.search(profileId, 'rubin')), isEmpty);
    });

    test('the LIKE fallback searches notes too', () async {
      final id = await episode('Episode 12');
      await db.feedsDao.fillNotes(id,
          html: '<p>Guest: Vera Rubin</p>', plain: 'Guest: Vera Rubin');
      final like = SearchStore(db, forceLike: true);
      expect(titles(await like.search(profileId, 'vera rubin')),
          ['Episode 12']);
    });
  });

  group('matching (1.5.4)', () {
    test('a word matches its other forms', () async {
      await episode('The charity that is also a time machine');
      for (final q in ['machines', 'time machines', 'charities']) {
        expect(titles(await store.search(profileId, q)),
            ['The charity that is also a time machine'],
            reason: q);
      }
    });

    test('every word is a prefix, not only the last', () async {
      await episode('Time machine');
      expect(titles(await store.search(profileId, 'tim machine')),
          ['Time machine']);
    });

    test('a contraction finds itself, not "it" beside any s-word',
        () async {
      await episode('It sings softly');
      await episode('It was summer');
      await episode('It’s raining');
      await episode("It's late");
      expect(titles(await store.search(profileId, "it's")).toSet(),
          {'It’s raining', "It's late"});
      expect(titles(await store.search(profileId, 'it’s rain')),
          ['It’s raining']);
    });

    test('a word in the title beside one in the notes still finds it',
        () async {
      final id = await episode('Aurora season');
      await db.feedsDao.fillNotes(id,
          html: '<p>Guest: Vera Rubin</p>', plain: 'Guest: Vera Rubin');
      expect(titles(await store.search(profileId, 'aurora rubin')),
          ['Aurora season']);
    });

    Future<int> post(String title, List<String> body, {int? feed}) async {
      final id = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'article',
          title: title,
          persistence: 'ephemeron',
          firstSeenEpochDay: 100,
          sourceUrl: 'https://blog.test/$title');
      // Ingest's order: the work, its body, then its feed row.
      await db.spineDao.insertSegments(id, [
        for (final (i, t) in body.indexed) (idx: i, kind: 'prose', text: t)
      ]);
      await db.feedsDao.insertEpisode(
          workId: id, feedId: feed ?? feedId, guid: title, publishedAtMs: 1);
      return id;
    }

    test('a blog post is found by a word in its body', () async {
      await post('Weeknotes', ['Mostly about bicycles.', 'And a zeppelin.']);
      expect(titles(await store.search(profileId, 'zeppelins')),
          ['Weeknotes']);
      expect(titles(await store.search(profileId, 'bicycle zeppelin')),
          ['Weeknotes']);
    });

    test('a book\'s body is not searched', () async {
      final id = await book('Plain cover');
      await db.spineDao.insertSegments(
          id, const [(idx: 0, kind: 'prose', text: 'A zeppelin inside.')]);
      expect(titles(await store.search(profileId, 'zeppelin')), isEmpty);
    });

    test('before its full notes arrive, an episode is found by its short '
        'description; the notes then take its place', () async {
      final id = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: 'Episode 9',
          persistence: 'ephemeron',
          firstSeenEpochDay: 100);
      await db.spineDao.insertSegments(id,
          const [(idx: 0, kind: 'prose', text: 'A talk about lighthouses.')]);
      await db.feedsDao.insertEpisode(
          workId: id,
          feedId: feedId,
          guid: 'e9',
          enclosureUrl: 'https://cast.test/9.mp3',
          publishedAtMs: 1);
      expect(titles(await store.search(profileId, 'lighthouse')),
          ['Episode 9']);
      await db.feedsDao.fillNotes(id,
          html: '<p>Keepers and lamps</p>', plain: 'Keepers and lamps');
      expect(titles(await store.search(profileId, 'lamp')), ['Episode 9']);
      expect(titles(await store.search(profileId, 'lighthouse')), isEmpty);
    });

    test('a transcript sentence is not show notes', () async {
      final id = await episode('Episode 3');
      await transcribe(id, ['We saw a narwhal.']);
      final r = await store.search(profileId, 'narwhal');
      expect(r.items, isEmpty);
      expect(r.said.single.item.work.id, id);
    });

    test('a show\'s name matches the way every other word does', () async {
      final ml = await db.feedsDao.insertFeed(
          profileId: profileId,
          url: 'https://ml.test/f',
          title: 'Machine Learning Weekly');
      expect((await store.search(profileId, 'machines')).shows.single.id, ml);
      expect((await store.search(profileId, 'mach learn')).shows.single.id,
          ml);
      await (db.update(db.feeds)..where((f) => f.id.equals(ml)))
          .write(const FeedsCompanion(title: Value('Deep Nets')));
      expect((await store.search(profileId, 'machine')).shows, isEmpty);
      expect((await store.search(profileId, 'nets')).shows.single.id, ml);
      await db.feedsDao.deleteFeedCascade(ml);
      expect((await store.search(profileId, 'nets')).shows, isEmpty);
    });
  });

  group('sections (1.5.4)', () {
    test('a title match comes in titles, a notes match in show notes, and '
        'a work found by both is listed once, in titles', () async {
      final inTitle = await episode('Charity season', publishedAtMs: 1);
      final inNotes = await episode('Episode 2', publishedAtMs: 2);
      await db.feedsDao.fillNotes(inNotes,
          html: '<p>a charity</p>', plain: 'About a charity drive.');
      await db.feedsDao.fillNotes(inTitle,
          html: '<p>a charity</p>', plain: 'Another charity.');
      final r = await store.search(profileId, 'charity');
      expect([for (final i in r.titleSection.rows) i.work.id], [inTitle]);
      expect([for (final i in r.notesSection.rows) i.work.id], [inNotes]);
      expect(r.titleSection.count, 1);
      expect(r.notesSection.count, 1);
    });

    test('a show\'s name puts its episodes in titles', () async {
      final id = await episode('Episode 2');
      final r = await store.search(profileId, 'night sky');
      expect([for (final i in r.titleSection.rows) i.work.id], [id]);
      expect(r.notesSection.count, 0);
    });

    test('words split between title and notes land in show notes', () async {
      final id = await episode('Aurora season');
      await db.feedsDao.fillNotes(id, html: '<p>Rubin</p>', plain: 'Rubin');
      final r = await store.search(profileId, 'aurora rubin');
      expect(r.titleSection.count, 0);
      expect([for (final i in r.notesSection.rows) i.work.id], [id]);
    });

    for (final like in [false, true]) {
      test('Said in lists every sentence, even of a work found above: the '
          'jump to the sentence is the point (${like ? 'LIKE' : 'index'})',
          () async {
        final s = SearchStore(db, forceLike: like);
        final titled = await episode('Comet night');
        await transcribe(titled, ['A comet, again.']);
        final other = await episode('Episode 4');
        await transcribe(other, ['The comet was bright.']);
        final r = await s.search(profileId, 'comet');
        expect([for (final i in r.items) i.work.id], [titled]);
        expect([for (final h in r.said) h.item.work.id], [other, titled]);
        expect(r.saidSection.count, 2);
      });
    }

    test('a post whose text is rewritten is found by its new words only',
        () async {
      final id = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'article',
          title: 'Weeknotes',
          persistence: 'ephemeron',
          firstSeenEpochDay: 100);
      await db.spineDao.insertSegments(
          id, const [(idx: 0, kind: 'prose', text: 'A short excerpt.')]);
      await db.feedsDao
          .insertEpisode(workId: id, feedId: feedId, guid: 'w', publishedAtMs: 1);
      // The full article replaces the excerpt, as an article fetch does.
      await db.customStatement('DELETE FROM segments WHERE work_id = ?', [id]);
      await db.spineDao.insertSegments(id, const [
        (idx: 0, kind: 'prose', text: 'All about zeppelins.'),
        (idx: 1, kind: 'prose', text: 'And airships.'),
      ]);
      expect(titles(await store.search(profileId, 'zeppelin airship')),
          ['Weeknotes']);
      expect(titles(await store.search(profileId, 'excerpt')), isEmpty);
      await db.customStatement(
          "UPDATE segments SET body = 'Blimps now.' WHERE work_id = ? AND idx = 1",
          [id]);
      expect(titles(await store.search(profileId, 'blimp')), ['Weeknotes']);
      expect(titles(await store.search(profileId, 'airship')), isEmpty);
    });

    test('notes that change are found by their new words only', () async {
      final id = await episode('Episode 8');
      await db.feedsDao.fillNotes(id, html: '<p>a</p>', plain: 'Lighthouses.');
      await db.customStatement(
          "UPDATE work_notes SET plain = 'Glaciers.' WHERE work_id = ?", [id]);
      expect(titles(await store.search(profileId, 'glacier')), ['Episode 8']);
      expect(titles(await store.search(profileId, 'lighthouse')), isEmpty);
    });

    for (final like in [false, true]) {
      test('each section says its true count past the first page, and '
          'pages through the rest, newest first '
          '(${like ? 'LIKE' : 'index'})', () async {
        final s = SearchStore(db, forceLike: like, pageSize: 5);
        final titled = [
          for (var i = 0; i < 150; i++)
            await episode('Machine $i', publishedAtMs: 1000 + i),
        ];
        // Fifty newer episodes with the word only in their notes.
        final noted = <int>[];
        for (var i = 0; i < 50; i++) {
          final id = await episode('Episode $i', publishedAtMs: 5000 + i);
          await db.feedsDao.fillNotes(id,
              html: '<p>machine</p>', plain: 'About a machine.');
          noted.add(id);
        }
        for (var i = 0; i < 12; i++) {
          final id = await book('Plain $i');
          await transcribe(id, ['The machine hums.']);
        }
        final r = await s.search(profileId, 'machine');
        expect(r.titleSection.count, 150);
        expect(r.titleSection.hasMore, isTrue);
        expect([for (final i in r.titleSection.rows) i.work.id],
            titled.reversed.take(5));
        expect(r.notesSection.count, 50);
        expect(r.saidSection.count, 12);
        expect(r.said, hasLength(5));
        final rest = await s.itemsPage(profileId, 'machine', SearchTier.titles,
            offset: 5, limit: 200);
        expect([for (final i in rest) i.work.id], titled.reversed.skip(5));
        final notes = await s.itemsPage(profileId, 'machine', SearchTier.notes,
            offset: 0, limit: 200);
        expect([for (final i in notes) i.work.id], noted.reversed);
        expect(await s.saidPage(profileId, 'machine', offset: 5, limit: 200),
            hasLength(7));
      });
    }

    test('shows say their count and page like every section', () async {
      for (var i = 0; i < 30; i++) {
        await db.feedsDao.insertFeed(
            profileId: profileId, url: 'https://p$i.test', title: 'Pod $i');
      }
      final r = await SearchStore(db, pageSize: 5).search(profileId, 'pod');
      expect(r.showSection.count, 30);
      expect(r.shows, hasLength(5));
      expect((await store.showsMatching(profileId, 'pod')), hasLength(30));
    });

    test('Library matches are kept works the words find in any section, '
        'and nothing unkept', () async {
      final kept = await episode('Kept charity');
      await db.spineDao.promoteWork(kept);
      await episode('Unkept charity');
      final noted = await episode('Episode 7');
      await db.feedsDao.fillNotes(noted, html: '<p>c</p>', plain: 'charity');
      await db.spineDao.promoteWork(noted);
      final saidBook = await book('Plain');
      await transcribe(saidBook, ['A charity drive.']);
      final mine = await store.libraryMatches(profileId, 'charities');
      expect(mine, {kept, noted, saidBook});
      expect(await SearchStore(db, forceLike: true)
          .libraryMatches(profileId, 'charity'), {kept, noted, saidBook});
    });
  });

  group('the index follows its rows', () {
    test('a fresh database carries it', () async {
      final rows = await db
          .customSelect("SELECT name FROM sqlite_master "
              "WHERE name IN ('items_fts', 'segments_fts')")
          .get();
      expect(rows, hasLength(2));
      // Every other test here would pass on the LIKE fallback too.
      expect(await store.usesIndex, isTrue);
    });

    test('a new title is found as it is typed', () async {
      await episode('Aurora season');
      expect(titles(await store.search(profileId, 'auro')), ['Aurora season']);
    });

    test('diacritics and case do not matter', () async {
      await book('Café Society');
      expect(titles(await store.search(profileId, 'cafe')), ['Café Society']);
    });

    test('a renamed work is found by its new name only', () async {
      final id = await episode('Aurora season');
      await (db.update(db.works)..where((w) => w.id.equals(id)))
          .write(const WorksCompanion(title: Value('Comet watch')));
      expect(titles(await store.search(profileId, 'aurora')), isEmpty);
      expect(titles(await store.search(profileId, 'comet')), ['Comet watch']);
    });

    test('a deleted work is gone from the index', () async {
      final id = await episode('Aurora season');
      await transcribe(id, ['The aurora was green tonight.']);
      await db.spineDao.deleteWork(id);
      final r = await store.search(profileId, 'aurora');
      expect(r.items, isEmpty);
      expect(r.said, isEmpty);
    });

    test('a show name finds its episodes, newest first', () async {
      await episode('First light', publishedAtMs: 1000);
      await episode('Second light', publishedAtMs: 2000);
      expect(titles(await store.search(profileId, 'night sky')),
          ['Second light', 'First light']);
    });

    test('a renamed show is found by its new name', () async {
      await episode('First light');
      await (db.update(db.feeds)..where((f) => f.id.equals(feedId)))
          .write(const FeedsCompanion(title: Value('Deep Field')));
      expect(titles(await store.search(profileId, 'night')), isEmpty);
      expect(titles(await store.search(profileId, 'deep field')),
          ['First light']);
    });

    Future<int> totalChanges() async => (await db
            .customSelect('SELECT total_changes() AS n')
            .getSingle())
        .read<int>('n');

    test('rewriting a show\'s title unchanged reindexes none of its '
        'episodes', () async {
      for (var i = 0; i < 20; i++) {
        await episode('Light $i');
      }
      final before = await totalChanges();
      // Raw, so the guard is what is tested, not the DAO's own skip.
      await db.customStatement(
          'UPDATE feeds SET title = title WHERE id = ?', [feedId]);
      expect(await totalChanges() - before, 1,
          reason: 'only the feed row itself changed');
      expect((await store.search(profileId, 'night sky')).titleSection.count,
          20);
    });

    test('a refresh with the same title changes one row and leaves the '
        'title unwritten', () async {
      await episode('First light');
      await db.customStatement('CREATE TEMP TABLE title_writes(n INTEGER)');
      await db.customStatement('CREATE TEMP TRIGGER count_title_writes '
          'AFTER UPDATE OF title ON feeds BEGIN '
          'INSERT INTO title_writes VALUES (1); END');
      final before = await totalChanges();
      await db.feedsDao.updateRefreshState(feedId,
          title: 'Night Sky Hour',
          etag: '"e"',
          lastModified: null,
          breakerJson: '{}');
      expect(await totalChanges() - before, 1);
      final writes = await db
          .customSelect('SELECT count(*) AS n FROM title_writes')
          .getSingle();
      expect(writes.read<int>('n'), 0);
      expect((await db.feedsDao.feedById(feedId))!.etag, '"e"');
      // A real rename still lands, and still reindexes.
      await db.feedsDao.updateRefreshState(feedId,
          title: 'Deep Field',
          etag: '"e"',
          lastModified: null,
          breakerJson: '{}');
      expect((await db.feedsDao.feedById(feedId))!.title, 'Deep Field');
      expect(titles(await store.search(profileId, 'deep field')),
          ['First light']);
    });

    test('words split between the show and the title still find it',
        () async {
      await episode('Episode 5');
      await episode('Episode 6');
      await episode('Episode 5', feed: await db.feedsDao.insertFeed(
          profileId: profileId, url: 'https://b.test/f', title: 'Serial'));
      final r = await store.search(profileId, 'night episode 5');
      expect([for (final i in r.items) (i.work.title, i.showTitle)],
          [('Episode 5', 'Night Sky Hour')]);
    });

    test('an unfollowed show leaves its kept episode findable by title only',
        () async {
      final id = await episode('Kept one');
      await db.spineDao.promoteWork(id);
      await db.feedsDao.deleteFeedCascade(feedId);
      expect(titles(await store.search(profileId, 'night')), isEmpty);
      expect(titles(await store.search(profileId, 'kept')), ['Kept one']);
    });

    test('a work matching by title and show is listed once', () async {
      await episode('Night sky notes');
      expect(titles(await store.search(profileId, 'night')),
          ['Night sky notes']);
    });

    test('another reader’s works never show', () async {
      final other = await db.profilesDao.create('Bo');
      await book('Aurora diary', profile: other);
      expect(titles(await store.search(profileId, 'aurora')), isEmpty);
    });
  });

  group('said in', () {
    test('the transcript query never scans a table', () async {
      final plan = await db.customSelect(
          'EXPLAIN QUERY PLAN ${SearchStore.saidSql}',
          variables: [
            Variable.withString('"x"'),
            Variable.withInt(1),
            Variable.withInt(10),
            Variable.withInt(0),
          ]).get();
      final details = [for (final r in plan) r.read<String>('detail')];
      // The subquery is the list of works found above, already matched.
      final scans = details.where((d) =>
          d.startsWith('SCAN ') &&
          !d.contains('VIRTUAL TABLE') &&
          !d.startsWith('SCAN (subquery'));
      expect(scans, isEmpty, reason: details.join('\n'));
      expect(details.join('\n'), isNot(contains('segments ')));
    });

    test('a transcript hit carries a marked snippet and its time', () async {
      final id = await episode('Episode 12');
      await transcribe(id, [
        'Welcome back to the show.',
        'Tonight the aurora reached as far south as Kansas.',
      ]);
      final hit = (await store.search(profileId, 'aurora')).said.single;
      expect(hit.item.work.id, id);
      expect(hit.segmentIdx, 1);
      expect(hit.tStartMs, 65000);
      final parts = parseSnippet(hit.snippet);
      expect(parts.where((p) => p.match).map((p) => p.text), ['aurora']);
      expect(parts.map((p) => p.text).join(), contains('reached as far'));
    });

    test('a sentence with no alignment is not a transcript', () async {
      final id = await book('Field guide');
      await db.spineDao.insertSegments(
          id, const [(idx: 0, kind: 'prose', text: 'The aurora explained.')]);
      expect((await store.search(profileId, 'aurora')).said, isEmpty);
    });

    test('a retranscribe replaces the old sentences', () async {
      final id = await episode('Episode 12');
      await transcribe(id, ['An aurora story.']);
      await db.transaction(() async {
        await (db.delete(db.alignments)..where((a) => a.workId.equals(id)))
            .go();
        await (db.delete(db.segments)..where((s) => s.workId.equals(id))).go();
        await transcribe(id, ['A comet story.']);
      });
      final r = await store.search(profileId, 'aurora');
      expect(r.said, isEmpty);
      expect((await store.search(profileId, 'comet')).said, hasLength(1));
    });

    test('an edited sentence is found by its new words', () async {
      final id = await episode('Episode 12');
      await transcribe(id, ['An aurora story.']);
      await (db.update(db.segments)..where((s) => s.workId.equals(id)))
          .write(const SegmentsCompanion(body: Value('A meteor story.')));
      expect((await store.search(profileId, 'aurora')).said, isEmpty);
      expect((await store.search(profileId, 'meteor')).said, hasLength(1));
    });
  });

  group('the snippet', () {
    test('splits on the match markers', () {
      final parts = parseSnippet('…the \u0002aurora\u0003 was \u0002green\u0003');
      expect([for (final p in parts) (p.text, p.match)], [
        ('…the ', false),
        ('aurora', true),
        (' was ', false),
        ('green', true),
      ]);
    });
  });

  group('history', () {
    Future<void> stampPosition(int workId, int at) async {
      await db.spineDao.savePosition(
          profileId: profileId,
          workId: workId,
          segmentIdx: 0,
          wordIdx: 3,
          lastModality: 'read');
      await db.customStatement(
          'UPDATE positions SET updated_at_ms = ? WHERE work_id = ?',
          [at, workId]);
    }

    Future<void> stampPlayer(int workId, int at) async {
      await db.feedsDao
          .savePlayerPosition(profileId: profileId, workId: workId, tMs: 10);
      await db.customStatement(
          'UPDATE player_positions SET updated_at_ms = ? WHERE work_id = ?',
          [at, workId]);
    }

    test('played, read and finished items, most recent first; untouched '
        'ones left out', () async {
      final finished = await episode('Finished');
      final listened = await episode('Listened');
      final read = await book('Read');
      await episode('Never touched');
      // Played to the end: what the player's finish writes.
      await db.spineDao.markFinished(finished, 1);
      await db.feedsDao.setFinished(finished, 3000);
      await stampPlayer(listened, 5000);
      await stampPosition(read, 4000);
      final h = await store.history(profileId);
      expect([for (final e in h) (e.item.work.title, e.atMs)],
          [('Listened', 5000), ('Read', 4000), ('Finished', 3000)]);
      expect(h.first.item.showTitle, 'Night Sky Hour');
      expect(h.first.item.episode, isNotNull);
      expect(h[1].item.episode, isNull);
    });

    test('the latest touch of an item is its place', () async {
      final id = await episode('Twice');
      await db.feedsDao.markPlayed(id, 1000);
      await stampPlayer(id, 9000);
      final h = await store.history(profileId);
      expect([for (final e in h) e.atMs], [9000]);
    });

    test('marked played without listening is not history', () async {
      final id = await episode('Cleared');
      await db.feedsDao.markPlayed(id, 5000);
      expect(await store.history(profileId), isEmpty);
    });

    test('opened but never moved is not history', () async {
      final heard = await episode('Barely');
      final read = await book('Unread');
      await db.feedsDao
          .savePlayerPosition(profileId: profileId, workId: heard, tMs: 0);
      await db.spineDao.savePosition(
          profileId: profileId,
          workId: read,
          segmentIdx: 0,
          wordIdx: 0,
          lastModality: 'read');
      expect(await store.history(profileId), isEmpty);
    });

    test('a triaged item is not history', () async {
      final id = await episode('Let pass');
      await db.feedsDao.markRead(id, 5000);
      expect(await store.history(profileId), isEmpty);
    });

    test('another reader’s history never shows', () async {
      final other = await db.profilesDao.create('Bo');
      final id = await book('Theirs', profile: other);
      await db.spineDao.savePosition(
          profileId: other,
          workId: id,
          segmentIdx: 1,
          wordIdx: 0,
          lastModality: 'read');
      expect(await store.history(profileId), isEmpty);
    });
  });

  group('grouped by day', () {
    final now = DateTime(2026, 10, 22, 9);
    int at(DateTime d) => d.millisecondsSinceEpoch;

    test('Today, Yesterday, then dates, by local calendar day', () {
      expect(dayLabel(at(DateTime(2026, 10, 22, 0, 5)), now), 'Today');
      expect(dayLabel(at(DateTime(2026, 10, 21, 23, 55)), now), 'Yesterday');
      expect(dayLabel(at(DateTime(2026, 10, 20, 12)), now), 'Tue 20 Oct');
      expect(dayLabel(at(DateTime(2025, 12, 31, 12)), now), 'Wed 31 Dec 2025');
    });

    test('runs of the same day share one heading', () {
      final groups = groupByDay(
          [at(DateTime(2026, 10, 22, 8)), at(DateTime(2026, 10, 22, 1)),
            at(DateTime(2026, 10, 20, 8))],
          (ms) => ms,
          now);
      expect([for (final g in groups) (g.label, g.items.length)],
          [('Today', 2), ('Tue 20 Oct', 1)]);
    });
  });

  group('schema migration v24 -> v25', () {
    test('a v24 database gains the index, filled from its rows', () async {
      final dir = Directory.systemTemp.createTempSync('trellis-migration-v25');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/v24.sqlite');

      final seed = AppDatabase.forTesting(NativeDatabase(file));
      final p = await seed.profilesDao.create('Ada');
      final f = await seed.feedsDao
          .insertFeed(profileId: p, url: 'https://a.test/f', title: 'Deep Field');
      final w = await seed.spineDao.insertWork(
          profileId: p,
          kind: 'episode',
          title: 'Aurora season',
          persistence: 'work',
          firstSeenEpochDay: 100,
          sourceUrl: 'https://a.test/a.mp3');
      await seed.feedsDao.insertEpisode(
          workId: w, feedId: f, guid: 'g', publishedAtMs: 1);
      await seed.spineDao.insertSegments(
          w, const [(idx: 0, kind: 'prose', text: 'A green comet tonight.')]);
      await seed.spineDao.insertAlignments(
          w, const [(segmentIdx: 0, tStartMs: 0, tEndMs: 1000)]);
      await seed.close();
      final v24 = raw.sqlite3.open(file.path);
      final triggers = v24
          .select("SELECT name FROM sqlite_master WHERE type = 'trigger' "
              "AND name LIKE '%fts%'")
          .map((r) => r['name'] as String)
          .toList();
      expect(triggers, isNotEmpty, reason: 'a fresh file carries the index');
      v24.execute(stripV26);
      for (final t in v24
          .select("SELECT name FROM sqlite_master WHERE type = 'trigger' "
              "AND name LIKE '%fts%'")
          .map((r) => r['name'] as String)
          .toList()) {
        v24.execute('DROP TRIGGER $t');
      }
      v24.execute('''
        DROP TABLE items_fts;
        DROP TABLE segments_fts;
        PRAGMA user_version = 24;
      ''');
      v24.dispose();

      final migrated = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(migrated.close);
      final s = SearchStore(migrated);
      expect(titles(await s.search(p, 'aurora')), ['Aurora season']);
      expect(titles(await s.search(p, 'deep')), ['Aurora season']);
      expect((await s.search(p, 'comet')).said.single.item.work.id, w);
      // And the triggers came back with it.
      await migrated.spineDao.insertWork(
          profileId: p,
          kind: 'book',
          title: 'Borealis',
          persistence: 'work',
          firstSeenEpochDay: 100);
      expect(titles(await s.search(p, 'borealis')), ['Borealis']);
    });
  });

  group('without FTS5', () {
    test('search falls back to LIKE and still finds titles and sentences',
        () async {
      final id = await episode('Aurora season');
      await transcribe(id, ['A green comet tonight.']);
      final s = SearchStore(db, forceLike: true);
      expect(titles(await s.search(profileId, 'roRA')), ['Aurora season']);
      expect(titles(await s.search(profileId, 'night sky')), ['Aurora season']);
      expect(titles(await s.search(profileId, 'night aurora')),
          ['Aurora season']);
      final hit = (await s.search(profileId, 'comet')).said.single;
      expect(parseSnippet(hit.snippet).where((p) => p.match).single.text,
          'comet');
    });
  });
}
