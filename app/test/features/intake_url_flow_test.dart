import 'dart:async';

import 'package:comms_core/comms_core.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/library/library_screen.dart';

import '../support/scripted_fetcher.dart';

/// URL intake (ADR-0003 law 6): the pasted address is shown at the ONE
/// consent chokepoint and NOTHING touches the wire before the explicit yes;
/// a confirmed article lands as a persistent spine work; every failure —
/// private-range refusal, feed XML, non-article, timeout, HTTP error — is a
/// sentence, never a stack.
void main() {
  late AppDatabase db;
  late Profile profile;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.profilesDao.create('Ada');
    profile = (await db.profilesDao.all()).single;
  });
  tearDown(() => db.close());

  const url = 'https://example.org/essay';

  final longA = 'A long paragraph about mulch and morning light in rows. ' * 4;
  final longB = 'Another long paragraph about raised beds and rain. ' * 4;
  final articleHtml = '<html><head><title>The Quiet Garden</title>'
      '<meta name="author" content="A. Gardener"></head>'
      '<body><article><p>$longA</p><p>$longB</p></article></body></html>';

  Future<ScriptedFetcher> pumpLibrary(WidgetTester tester,
      {FutureOr<FetchResponse> Function(Uri, Map<String, String>?)?
          handler}) async {
    final fetcher = ScriptedFetcher(handler ??
        (u, h) => textResponse(articleHtml,
            headers: {'content-type': 'text/html; charset=utf-8'}));
    await tester.pumpWidget(MaterialApp(
        home: LibraryScreen(
            db: db,
            profile: profile,
            onSwitchProfile: () {},
            fetcher: fetcher)));
    await tester.pumpAndSettle();
    return fetcher;
  }

  Future<void> openAndFetch(WidgetTester tester, String address) async {
    await tester.tap(find.text('From the web'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('url-intake-field')), address);
    await tester.tap(find.byKey(const Key('url-intake-fetch')));
    await tester.pumpAndSettle();
  }

  String errorSentence(WidgetTester tester) =>
      (tester.widget<Text>(find.byKey(const Key('url-intake-error')))).data!;

  testWidgets('nothing is fetched before the explicit yes (ADR-0003 law 6)',
      (tester) async {
    final fetcher = await pumpLibrary(tester);
    await openAndFetch(tester, url);

    // The chokepoint names exactly what would leave the device: the URL.
    expect(find.byKey(const Key('consent-dialog')), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const Key('consent-dialog')),
            matching: find.textContaining(url)),
        findsOneWidget);
    expect(fetcher.calls, isEmpty,
        reason: 'no byte may move before the user says yes');

    await tester.tap(find.byKey(const Key('consent-cancel')));
    await tester.pumpAndSettle();
    expect(fetcher.calls, isEmpty);
    expect(find.byKey(const Key('url-intake-field')), findsOneWidget,
        reason: 'declining calmly returns to the input');
  });

  testWidgets('consent -> fetch -> preview -> confirm lands the article',
      (tester) async {
    final fetcher = await pumpLibrary(tester);
    await openAndFetch(tester, url);
    await tester.tap(find.byKey(const Key('consent-accept')));
    await tester.pumpAndSettle();

    expect(fetcher.calls.single.url.toString(), url);
    expect(find.text('The Quiet Garden'), findsOneWidget);
    expect(find.textContaining('A. Gardener'), findsOneWidget);
    expect(find.text('2 passages'), findsOneWidget);

    await tester.tap(find.byKey(const Key('url-intake-add')));
    await tester.pumpAndSettle();

    // Back in the library, the work is on the shelf.
    expect(find.text('The Quiet Garden'), findsOneWidget);

    final work = (await db.spineDao.worksOf(profile.id)).single;
    expect(work.kind, 'article');
    expect(work.persistence, 'work', reason: 'spine row, not an ephemeron');
    expect(work.sourceUrl, url);
    expect(work.title, 'The Quiet Garden');
    expect(await db.spineDao.segmentCount(work.id), 2);

    // The add sheet offers the web door too, not just the empty state.
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('From the web'), findsOneWidget);
  });

  testWidgets('a private-network address is refused BEFORE consent',
      (tester) async {
    final fetcher = await pumpLibrary(tester);
    await openAndFetch(tester, 'http://192.168.1.10/admin');

    expect(find.byKey(const Key('consent-dialog')), findsNothing,
        reason: 'a lexically refused URL never reaches the chokepoint');
    expect(fetcher.calls, isEmpty);
    expect(errorSentence(tester),
        "Local and private-network addresses can't be loaded.");
  });

  testWidgets('feed XML yields a pointer to the River, not raw XML',
      (tester) async {
    final fetcher = await pumpLibrary(tester,
        handler: (u, h) => textResponse(
            '<?xml version="1.0"?><rss version="2.0"><channel>'
            '<title>P</title></channel></rss>'));
    await openAndFetch(tester, url);
    await tester.tap(find.byKey(const Key('consent-accept')));
    await tester.pumpAndSettle();

    expect(fetcher.calls, hasLength(1));
    expect(errorSentence(tester), contains('River'));
    expect((await db.spineDao.worksOf(profile.id)), isEmpty);
  });

  testWidgets('a page with no readable article yields a sentence',
      (tester) async {
    await pumpLibrary(tester,
        handler: (u, h) => textResponse(
            '<html><head><title>Tiny</title></head><body><article>'
            '<p>Too short to be an article, really.</p>'
            '</article></body></html>',
            headers: {'content-type': 'text/html'}));
    await openAndFetch(tester, url);
    await tester.tap(find.byKey(const Key('consent-accept')));
    await tester.pumpAndSettle();

    expect(errorSentence(tester),
        'No readable article was found at that address.');
  });

  testWidgets('a timeout yields a sentence, never a stack', (tester) async {
    await pumpLibrary(tester,
        handler: (u, h) => throw TimeoutException('deadline'));
    await openAndFetch(tester, url);
    await tester.tap(find.byKey(const Key('consent-accept')));
    await tester.pumpAndSettle();

    expect(errorSentence(tester), contains('too long'));
  });

  testWidgets('an HTTP error status yields a sentence', (tester) async {
    await pumpLibrary(tester,
        handler: (u, h) => textResponse('gone', status: 500));
    await openAndFetch(tester, url);
    await tester.tap(find.byKey(const Key('consent-accept')));
    await tester.pumpAndSettle();

    expect(errorSentence(tester), 'The site answered with an error (500).');
  });
}
