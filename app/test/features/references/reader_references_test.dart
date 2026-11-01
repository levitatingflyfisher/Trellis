import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_prefs.dart';
import 'package:trellis/features/reader/reader_screen.dart';

import '../../support/scripted_fetcher.dart';

/// Frozen references in the reader (owner, 21 and 24 Oct 2026): a saved
/// article's linked words look like links; a tap offers the kept copy,
/// keeping one, or the browser; Linked pages keeps them all.
void main() {
  late AppDatabase db;
  late int p;
  late int workId;
  late List<Uri> opened;

  final words = 'Plain sentences about tides and the moon that run long. ' * 5;
  String page(String title) => '<html><head><title>$title</title></head>'
      '<body><article><p>$words</p></article></body></html>';

  const body = 'Spring tides follow the moon, as the almanac shows.';

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    p = await db.profilesDao.create('Ada');
    workId = await db.spineDao.insertWork(
        profileId: p,
        kind: 'article',
        title: 'Tides',
        persistence: 'work',
        firstSeenEpochDay: 100,
        lang: 'en');
    await db.spineDao.insertSegments(
        workId, const [(idx: 0, kind: 'prose', text: body)]);
    final moon = body.indexOf('the moon');
    final almanac = body.indexOf('almanac');
    await db.spineDao.insertLinks(workId, [
      (segIdx: 0, start: moon, end: moon + 8, href: 'https://moon.test/#a'),
      (
        segIdx: 0,
        start: almanac,
        end: almanac + 7,
        href: 'https://almanac.test/2026'
      ),
    ]);
    await db.profilesDao.updateReaderPrefs(
        p, (x) => x.copyWith(session: const ReaderSession(mode: 'scroll')));
    opened = [];
  });
  tearDown(() => db.close());

  ScriptedFetcher serving(Map<String, String> pages) =>
      ScriptedFetcher((u, h) {
        final b = pages[u.toString()];
        return b == null
            ? textResponse('gone', status: 404)
            : textResponse(b, headers: {'content-type': 'text/html'});
      });

  Future<void> pumpReader(WidgetTester tester, {ScriptedFetcher? fetcher}) async {
    final work = (await db.spineDao.workById(workId))!;
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(
            db: db,
            profileId: p,
            work: work,
            fetcher: fetcher,
            openLink: (uri) async => opened.add(uri))));
    await tester.pumpAndSettle();
  }

  testWidgets('linked words look like links; the others do not',
      (tester) async {
    await pumpReader(tester);
    TextDecoration? look(Finder f) => tester.widget<Text>(f).style?.decoration;
    expect(look(find.text('moon,')), TextDecoration.underline);
    expect(look(find.text('almanac')), TextDecoration.underline);
    // "the moon" is one link, "the almanac" is not: the same word, two looks.
    expect(look(find.text('the').first), TextDecoration.underline);
    expect(look(find.text('the').last), isNot(TextDecoration.underline));
    expect(look(find.text('tides')), isNot(TextDecoration.underline));
  });

  testWidgets('a page not kept: keep a copy asks first, then opens the copy',
      (tester) async {
    final f = serving({'https://moon.test/': page('The moon')});
    await pumpReader(tester, fetcher: f);

    await tester.tap(find.text('moon,'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('link-read-kept')), findsNothing);
    await tester.tap(find.byKey(const Key('link-keep')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('consent-dialog')), findsOneWidget);
    expect(f.calls, isEmpty, reason: 'nothing leaves before the yes');
    expect(find.textContaining('https://moon.test/'), findsWidgets);

    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(f.calls.single.url.toString(), 'https://moon.test/');
    expect(find.text('The moon'), findsWidgets,
        reason: 'the kept copy opens in a reader of its own');
    expect((await db.spineDao.keptCopyOf(p, 'https://moon.test/'))?.title,
        'The moon');
  });

  testWidgets('a kept page opens from the sheet with no fetch',
      (tester) async {
    await db.spineDao.storeKeptCopy(
        profileId: p,
        href: 'https://moon.test/',
        title: 'Kept moon page',
        epochDay: 20406,
        rows: const [(idx: 0, kind: 'prose', text: 'Kept words here.')]);
    final f = serving({});
    await pumpReader(tester, fetcher: f);

    await tester.tap(find.text('moon,'));
    await tester.pumpAndSettle();
    expect(find.text('Kept on 14 Nov 2025'), findsOneWidget);
    await tester.tap(find.byKey(const Key('link-read-kept')));
    await tester.pumpAndSettle();
    expect(find.text('Kept moon page'), findsWidgets);
    expect(f.calls, isEmpty);
  });

  testWidgets('a page that cannot be kept says why, in a sentence',
      (tester) async {
    await pumpReader(tester, fetcher: serving({}));
    await tester.tap(find.text('almanac'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('link-keep')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(find.textContaining('404'), findsOneWidget);
  });

  testWidgets('with no fetcher there is no keeping; the browser still opens',
      (tester) async {
    await pumpReader(tester);
    await tester.tap(find.text('almanac'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('link-keep')), findsNothing);
    await tester.tap(find.byKey(const Key('link-open-browser')));
    await tester.pumpAndSettle();
    expect(opened, [Uri.parse('https://almanac.test/2026')]);
  });

  testWidgets('Linked pages lists each page and keeps them all after one yes',
      (tester) async {
    final f = serving({
      'https://moon.test/': page('The moon'),
      'https://almanac.test/2026': page('Almanac'),
    });
    await pumpReader(tester, fetcher: f);
    await tester.tap(find.byKey(const Key('reader-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('linked-pages-action')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('linked-pages')), findsOneWidget);
    expect(find.text('the moon'), findsOneWidget);
    expect(find.text('2 of 2 not kept yet, from 2 sites.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('linked-pages-keep-all')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('consent-dialog')), findsOneWidget);
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();

    expect([for (final c in f.calls) c.url.toString()],
        ['https://moon.test/', 'https://almanac.test/2026']);
    expect(
        find.text('Every page this text links to is kept on this device.'),
        findsOneWidget);
  });

  testWidgets('a text with no links has no Linked pages', (tester) async {
    await (db.delete(db.segmentLinks)).go();
    await pumpReader(tester);
    await tester.tap(find.byKey(const Key('reader-overflow')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('linked-pages-action')), findsNothing);
  });
}
