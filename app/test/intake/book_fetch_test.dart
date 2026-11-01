import 'package:comms_core/comms_core.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/intake/article_fetch.dart';
import 'package:trellis/features/intake/book_fetch.dart';
import 'package:trellis/features/intake/url_intake.dart';

import '../support/docx_fixture.dart';
import '../support/scripted_fetcher.dart';

/// "Open a link" for a Word document and for a web book's contents page
/// (owner, 17 Nov 2026). The shape follows David Friedman's "Legal
/// Systems Very Different from Ours": a contents page of links to .docx
/// chapters. The words are stand-ins.
const _site = 'http://books.test/Legal%20Systems/';

FetchResponse _docx(List<int> bytes) => FetchResponse(
    statusCode: 200,
    headers: const {
      'content-type':
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
    },
    body: Stream.value(bytes));

FetchResponse _html(String body) =>
    textResponse(body, headers: {'content-type': 'text/html; charset=utf-8'});

const _contents = '<html><head><title>Legal Systems Very Different From Ours'
    '</title></head><body><p>A late draft.</p>'
    '<p><a href="Introduction.docx">Introduction</a></p>'
    '<p>1. <a href="Iceland.docx">Saga-Period Iceland</a></p>'
    '<p>2. <a href="Somali.html">Somali Law</a></p>'
    '<p>3. <a href="Feud.docx">Feud Law</a></p>'
    '<p><a href="Complete.docx">The whole book as one file</a></p>'
    '</body></html>';

final _somali = '<html><body><article><p>${'Clans pay blood money. ' * 12}'
    '<a href="https://example.org/xeer">Xeer</a></p></article></body></html>';

Map<String, FetchResponse Function()> _book() => {
      '${_site}Contents.htm': () => _html(_contents),
      '${_site}Introduction.docx': () => _docx(tinyDocx(heading: 'Introduction')),
      '${_site}Iceland.docx': () => _docx(tinyDocx()),
      '${_site}Somali.html': () => _html(_somali),
      '${_site}Feud.docx': () => _docx(tinyDocx(heading: 'Feud Law')),
    };

ScriptedFetcher _fetcher(Map<String, FetchResponse Function()> pages) =>
    ScriptedFetcher((u, _) {
      final page = pages[u.toString()];
      if (page == null) throw const CommsException('offline');
      return page();
    });

void main() {
  test('a link to a Word document reads it', () async {
    final out = await fetchLink(
        fetcher: _fetcher(_book()), url: Uri.parse('${_site}Iceland.docx'));
    final rows = (out as LinkDocument).rows;
    expect(rows.title, 'Iceland');
    expect(rows.rows.first.text, 'Saga-Period Iceland');
  });

  test('a contents page offers its book, and the whole-book file is not a '
      'chapter', () async {
    final out = await fetchLink(
        fetcher: _fetcher(_book()), url: Uri.parse('${_site}Contents.htm'));
    final book = (out as LinkPage).book!;
    expect(book.title, 'Legal Systems Very Different From Ours');
    expect([for (final c in book.chapters) c.title],
        ['Introduction', 'Saga-Period Iceland', 'Somali Law', 'Feud Law']);
    expect(out.article, isA<ArticleRefused>(),
        reason: 'the page itself is too short to be an article');
  });

  test('the book comes in chapter by chapter, in order, each opening with '
      'its title', () async {
    final page = await fetchLink(
        fetcher: _fetcher(_book()), url: Uri.parse('${_site}Contents.htm'));
    final heard = <(int, int)>[];
    final out = await fetchBook(
        fetcher: _fetcher(_book()),
        book: (page as LinkPage).book!,
        onChapter: (done, total) => heard.add((done, total)));
    final rows = (out as BookFetched).rows;
    expect(rows.title, 'Legal Systems Very Different From Ours');
    expect([for (final r in rows.rows) if (r.kind == 'heading') r.text], [
      'Introduction', 'Notes',
      'Saga-Period Iceland', 'Notes',
      'Somali Law',
      'Feud Law', 'Notes',
    ]);
    expect([for (final (i, r) in rows.rows.indexed) r.idx == i], everyElement(isTrue));
    // Each link still points at its words, wherever its chapter landed.
    for (final l in rows.links) {
      final text = rows.rows[l.segIdx].text;
      expect(text.substring(l.start, l.end),
          l.href.contains('xeer') ? 'Xeer' : 'you');
    }
    expect(rows.links, hasLength(4));
    expect(heard, [(0, 4), (1, 4), (2, 4), (3, 4), (4, 4)]);
  });

  test('a chapter that cannot be fetched stops the book, naming it',
      () async {
    final pages = _book()..remove('${_site}Somali.html');
    final page = await fetchLink(
        fetcher: _fetcher(pages), url: Uri.parse('${_site}Contents.htm'));
    final out = await fetchBook(
        fetcher: _fetcher(pages), book: (page as LinkPage).book!);
    expect((out as BookRefused).message, startsWith('“Somali Law” couldn’t be brought in.'));
  });

  group('Open a link', () {
    late AppDatabase db;
    late int profileId;
    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      profileId = await db.profilesDao.create('Ada');
    });
    tearDown(() => db.close());

    Future<int?> openBook(WidgetTester t, ScriptedFetcher fetcher) async {
      int? popped;
      await t.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => TextButton(
                  onPressed: () async {
                    popped = await Navigator.of(context).push<int>(
                        MaterialPageRoute(
                            builder: (_) => UrlIntakeScreen(
                                db: db,
                                profileId: profileId,
                                fetcher: fetcher)));
                  },
                  child: const Text('open')))));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.enterText(
          find.byKey(const Key('url-intake-field')), '${_site}Contents.htm');
      await t.tap(find.byKey(const Key('url-intake-fetch')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('consent-accept')));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await t.pumpAndSettle();
      return popped;
    }

    testWidgets('a contents page offers the book; after a consent that '
        'names every chapter, the book lands as one work', (t) async {
      final fetcher = _fetcher(_book());
      await openBook(t, fetcher);
      expect(find.byKey(const Key('url-intake-book-chapters')), findsOneWidget);
      expect(find.textContaining('A book of 4 chapters: Introduction'),
          findsOneWidget);
      expect(find.byKey(const Key('url-intake-add')), findsNothing,
          reason: 'the contents page itself is no article to add');

      await t.tap(find.byKey(const Key('url-intake-add-book')));
      await t.pumpAndSettle();
      for (final name in ['Introduction.docx', 'Iceland.docx', 'Somali.html', 'Feud.docx']) {
        expect(find.textContaining('$_site$name'), findsOneWidget, reason: name);
      }
      expect(find.textContaining('Complete.docx'), findsNothing);
      final before = fetcher.calls.length;
      await t.tap(find.byKey(const Key('consent-accept')));
      for (var i = 0; i < 20; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await t.pump();
      }
      await t.pumpAndSettle();
      expect(fetcher.calls.length - before, 4);

      final work = (await db.spineDao.worksOf(profileId)).single;
      expect(work.title, 'Legal Systems Very Different From Ours');
      expect(work.kind, 'book');
      expect(work.sourceUrl, '${_site}Contents.htm');
      expect(find.byType(UrlIntakeScreen), findsNothing);
    });

    testWidgets('saying no to the chapters fetches nothing more', (t) async {
      final fetcher = _fetcher(_book());
      await openBook(t, fetcher);
      final before = fetcher.calls.length;
      await t.tap(find.byKey(const Key('url-intake-add-book')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('consent-cancel')));
      await t.pumpAndSettle();
      expect(fetcher.calls.length, before);
      expect(await db.spineDao.worksOf(profileId), isEmpty);
    });
  });
}
