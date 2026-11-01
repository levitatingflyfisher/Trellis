import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:trellis/db/database.dart';
import 'package:trellis/features/library/library_query.dart';

import '../support/schema_strip.dart';

/// Frozen references (owner, 21 and 24 Oct 2026): a saved article keeps
/// where its links are, and a page one of them points to can be kept on
/// the device as a work of kind `frozen`, one per profile and address.
void main() {
  late AppDatabase db;
  late int p;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    p = await db.profilesDao.create('Ada');
  });
  tearDown(() => db.close());

  Future<int> article(String title, List<String> hrefs) async {
    final w = await db.spineDao.insertWork(
        profileId: p,
        kind: 'article',
        title: title,
        persistence: 'work',
        firstSeenEpochDay: 1);
    await db.spineDao.insertSegments(w, [
      (idx: 0, kind: 'prose', text: 'one two three four five six'),
    ]);
    await db.spineDao.insertLinks(w, [
      for (var i = 0; i < hrefs.length; i++)
        (segIdx: 0, start: i * 4, end: i * 4 + 3, href: hrefs[i]),
    ]);
    return w;
  }

  Future<int> keep(String href, {List<String> links = const []}) =>
      db.spineDao.storeKeptCopy(
          profileId: p,
          href: href,
          title: 'Copy of $href',
          epochDay: 20000,
          rows: const [(idx: 0, kind: 'prose', text: 'kept words here')],
          links: [
            for (final l in links) (segIdx: 0, start: 0, end: 4, href: l),
          ]);

  test('links come back in text order', () async {
    final w = await article('A', ['https://a.test/1', 'https://b.test/2']);
    final links = await db.spineDao.linksOf(w);
    expect([for (final l in links) (l.segIdx, l.startChar, l.endChar, l.href)],
        [(0, 0, 3, 'https://a.test/1'), (0, 4, 7, 'https://b.test/2')]);
  });

  test('a kept copy is found by its address, fragment or not', () async {
    expect(await db.spineDao.keptCopyOf(p, 'https://a.test/1'), isNull);
    final k = await keep('https://a.test/1#intro');
    final found = await db.spineDao.keptCopyOf(p, 'https://a.test/1#later');
    expect(found?.id, k);
    expect(found?.kind, 'frozen');
    expect(found?.sourceUrl, 'https://a.test/1');
    expect(found?.firstSeenEpochDay, 20000);
    expect(await db.spineDao.segmentsOf(k), hasLength(1));
  });

  test('the Library never lists a kept copy', () async {
    final k = await keep('https://a.test/1');
    expect(libraryKindOf((await db.spineDao.workById(k))!, null), isNull);
  });

  test('keeping an address twice keeps one copy', () async {
    final a = await keep('https://a.test/1');
    final b = await keep('https://a.test/1');
    expect(b, a);
    final all = await (db.select(db.works)
          ..where((w) => w.kind.equals('frozen')))
        .get();
    expect(all, hasLength(1));
  });

  test('another profile has its own copies', () async {
    await keep('https://a.test/1');
    final q = await db.profilesDao.create('Bo');
    expect(await db.spineDao.keptCopyOf(q, 'https://a.test/1'), isNull);
  });

  test('keptCopiesFor answers many addresses at once', () async {
    final k = await keep('https://a.test/1');
    final m = await db.spineDao
        .keptCopiesFor(p, ['https://a.test/1#x', 'https://none.test/']);
    expect(m.keys, ['https://a.test/1#x']);
    expect(m['https://a.test/1#x']!.id, k);
  });

  test('removing a work takes its links and the copies nothing else links to',
      () async {
    final a = await article('A', ['https://a.test/1', 'https://s.test/']);
    await article('B', ['https://s.test/']);
    final only = await keep('https://a.test/1',
        links: ['https://deep.test/']); // kept from inside the copy
    final deep = await keep('https://deep.test/');
    final shared = await keep('https://s.test/');
    await db.spineDao.deleteWork(a);
    expect(await db.spineDao.linksOf(a), isEmpty);
    expect(await db.spineDao.workById(only), isNull);
    expect(await db.spineDao.workById(deep), isNull,
        reason: 'only reached through the copy that went');
    expect(await db.spineDao.linksOf(only), isEmpty);
    expect((await db.spineDao.workById(shared))?.id, shared,
        reason: 'B still links to it');
  });

  test('two copies linking to each other still go when nothing else does',
      () async {
    final a = await article('A', ['https://x.test/']);
    final x = await keep('https://x.test/', links: ['https://y.test/']);
    final y = await keep('https://y.test/', links: ['https://x.test/']);
    await db.spineDao.deleteWork(a);
    expect(await db.spineDao.workById(x), isNull);
    expect(await db.spineDao.workById(y), isNull);
  });

  test('replaceBody replaces the links too', () async {
    final a = await article('A', ['https://a.test/1']);
    await db.spineDao.replaceBody(a,
        kind: 'article',
        title: 'A2',
        rows: const [(idx: 0, kind: 'prose', text: 'new body text')],
        links: const [(segIdx: 0, start: 4, end: 8, href: 'https://n.test/')]);
    expect([for (final l in await db.spineDao.linksOf(a)) l.href],
        ['https://n.test/']);
  });

  test('schema migration v35 -> v36 adds the links table, keeping every row',
      () async {
    final dir = Directory.systemTemp.createTempSync('trellis-migration-v36');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/v35.sqlite');
    final seed = AppDatabase.forTesting(NativeDatabase(file));
    final q = await seed.profilesDao.create('Ada');
    final w = await seed.spineDao.insertWork(
        profileId: q,
        kind: 'article',
        title: 'Old',
        persistence: 'work',
        firstSeenEpochDay: 1);
    await seed.close();

    final v35 = raw.sqlite3.open(file.path);
    v35.execute('$stripV36\nPRAGMA user_version = 35;');
    v35.dispose();

    final migrated = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(migrated.close);
    expect((await migrated.spineDao.workById(w))?.title, 'Old');
    expect(await migrated.spineDao.linksOf(w), isEmpty);
    await migrated.spineDao.insertLinks(
        w, const [(segIdx: 0, start: 0, end: 3, href: 'https://a.test/')]);
    expect(await migrated.spineDao.linksOf(w), hasLength(1));
  });
}
