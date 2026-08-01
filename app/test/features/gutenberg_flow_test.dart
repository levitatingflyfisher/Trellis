import 'dart:async';
import 'dart:convert';

import 'package:comms_core/comms_core.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/library/library_screen.dart';

import '../support/scripted_fetcher.dart';

/// Project Gutenberg intake: the search screen names its endpoint plainly
/// and nothing touches the wire before type + submit (the gesture); the book
/// download passes the ONE consent chokepoint naming the exact file URL;
/// a confirmed import lands boilerplate-stripped, unwrapped paragraphs as a
/// persistent 'book' work; every failure is a sentence.
void main() {
  late AppDatabase db;
  late Profile profile;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.profilesDao.create('Ada');
    profile = (await db.profilesDao.all()).single;
  });
  tearDown(() => db.close());

  const textUrl = 'https://files.test/4321/4321-0.txt';
  const htmlUrl = 'https://files.test/77/77-h.htm';

  final searchJson = jsonEncode({
    'count': 3,
    'next': null,
    'results': [
      {
        'id': 4321,
        'title': 'The Quiet Garden',
        'authors': [
          {'name': 'Gardener, A.', 'birth_year': 1800, 'death_year': 1870}
        ],
        'languages': ['en'],
        'formats': {
          'text/plain; charset=utf-8': textUrl,
          'text/html': 'https://files.test/4321/4321-h.htm',
        },
        'download_count': 512,
      },
      {
        'id': 77,
        'title': 'Hedgerows (HTML only)',
        'authors': [
          {'name': 'Rowan, B.'}
        ],
        'languages': ['en'],
        'formats': {'text/html; charset=utf-8': htmlUrl},
        'download_count': 41,
      },
      {
        'id': 999,
        'title': 'Audio Curiosity',
        'authors': <Map<String, Object?>>[],
        'languages': ['en'],
        'formats': {'audio/mpeg': 'https://files.test/999.mp3'},
        'download_count': 7,
      },
    ],
  });

  const bookText = 'The Project Gutenberg eBook of The Quiet Garden\n'
      'This eBook is for the use of anyone anywhere.\n'
      '*** START OF THE PROJECT GUTENBERG EBOOK THE QUIET GARDEN ***\n'
      'It was a quiet garden\nwith rows of beans\nand morning light.\n'
      '\n'
      'The second paragraph\nstays second.\n'
      '\n*** END OF THE PROJECT GUTENBERG EBOOK THE QUIET GARDEN ***\n'
      'License trailer text here.';

  const bookHtml = '<html><body>'
      '<p>*** START OF THE PROJECT GUTENBERG EBOOK HEDGEROWS ***</p>'
      '<h1>Hedgerows</h1>'
      '<p>A hawthorn line against\nthe west wind.</p>'
      '<p>*** END OF THE PROJECT GUTENBERG EBOOK HEDGEROWS ***</p>'
      '</body></html>';

  FetchResponse route(Uri u, Map<String, String>? h) {
    if (u.host == 'gutendex.com') {
      return textResponse(searchJson,
          headers: {'content-type': 'application/json'});
    }
    if (u.toString() == textUrl) {
      return textResponse(bookText,
          headers: {'content-type': 'text/plain; charset=utf-8'});
    }
    if (u.toString() == htmlUrl) {
      return textResponse(bookHtml,
          headers: {'content-type': 'text/html; charset=utf-8'});
    }
    return textResponse('lost', status: 404);
  }

  Future<ScriptedFetcher> pumpLibrary(WidgetTester tester,
      {FutureOr<FetchResponse> Function(Uri, Map<String, String>?)?
          handler}) async {
    final fetcher = ScriptedFetcher(handler ?? route);
    await tester.pumpWidget(MaterialApp(
        home: LibraryScreen(
            db: db,
            profile: profile,
            onSwitchProfile: () {},
            fetcher: fetcher)));
    await tester.pumpAndSettle();
    return fetcher;
  }

  Future<void> search(WidgetTester tester, String query) async {
    await tester.tap(find.text('Project Gutenberg'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('gutenberg-search-field')), query);
    await tester.tap(find.byKey(const Key('gutenberg-search-submit')));
    await tester.pumpAndSettle();
  }

  testWidgets('the empty state offers the Gutenberg door and the screen '
      'names its endpoint before anything fires', (tester) async {
    final fetcher = await pumpLibrary(tester);
    expect(find.text('Project Gutenberg'), findsOneWidget);

    await tester.tap(find.text('Project Gutenberg'));
    await tester.pumpAndSettle();

    // The screen says where search words go — plainly, before any search.
    expect(find.textContaining('gutendex.com'), findsOneWidget);
    expect(fetcher.calls, isEmpty,
        reason: 'opening the screen fires nothing; type + submit is '
            'the gesture');
  });

  testWidgets('the add sheet offers the Gutenberg door too', (tester) async {
    await db.spineDao.insertWork(
        profileId: profile.id,
        kind: 'note',
        title: 'Existing',
        persistence: 'work',
        firstSeenEpochDay: 0);
    await pumpLibrary(tester);

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('Project Gutenberg'), findsOneWidget);
  });

  testWidgets('type + submit searches gutendex.com once and lists results',
      (tester) async {
    final fetcher = await pumpLibrary(tester);
    await search(tester, 'quiet garden');

    final call = fetcher.calls.single;
    expect(call.url.host, 'gutendex.com');
    expect(call.url.queryParameters['search'], 'quiet garden');

    expect(find.text('The Quiet Garden'), findsOneWidget);
    expect(find.textContaining('Gardener, A.'), findsOneWidget);
    expect(find.textContaining('512'), findsOneWidget,
        reason: 'download count is shown');
  });

  testWidgets('importing passes the ONE consent chokepoint naming the file '
      'URL, and cancel moves no byte', (tester) async {
    final fetcher = await pumpLibrary(tester);
    await search(tester, 'quiet garden');

    await tester.tap(find.text('The Quiet Garden'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('consent-dialog')), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const Key('consent-dialog')),
            matching: find.textContaining(textUrl)),
        findsOneWidget,
        reason: 'the chokepoint names exactly what would leave the device');
    expect(fetcher.calls, hasLength(1),
        reason: 'only the search has run; the book has not moved');

    await tester.tap(find.byKey(const Key('consent-cancel')));
    await tester.pumpAndSettle();
    expect(fetcher.calls, hasLength(1));
  });

  testWidgets('a confirmed import lands the stripped, unwrapped book as a '
      'persistent work that opens like any other', (tester) async {
    await pumpLibrary(tester);
    await search(tester, 'quiet garden');
    await tester.tap(find.text('The Quiet Garden'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('consent-accept')));
    await tester.pumpAndSettle();

    // Back in the library with the book on the shelf.
    expect(find.text('The Quiet Garden'), findsOneWidget);

    final work = (await db.spineDao.worksOf(profile.id)).single;
    expect(work.kind, 'book');
    expect(work.persistence, 'work');
    expect(work.sourceUrl, textUrl);

    final segments = await db.spineDao.segmentsOf(work.id);
    expect(segments, hasLength(2), reason: 'blank line = paragraph break');
    expect(segments[0].body,
        'It was a quiet garden with rows of beans and morning light.',
        reason: 'hard-wrapped lines unwrap into one paragraph');
    expect(segments[1].body, 'The second paragraph stays second.');
    for (final s in segments) {
      expect(s.body, isNot(contains('Project Gutenberg')),
          reason: 'boilerplate header/footer stripped');
    }
  });

  testWidgets('an html-only edition imports through the html path',
      (tester) async {
    await pumpLibrary(tester);
    await search(tester, 'hedgerows');
    await tester.tap(find.text('Hedgerows (HTML only)'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('consent-accept')));
    await tester.pumpAndSettle();

    final work = (await db.spineDao.worksOf(profile.id)).single;
    expect(work.sourceUrl, htmlUrl);
    final segments = await db.spineDao.segmentsOf(work.id);
    expect([for (final s in segments) s.body],
        ['Hedgerows', 'A hawthorn line against the west wind.']);
  });

  testWidgets('a book with no readable edition is refused BEFORE consent',
      (tester) async {
    final fetcher = await pumpLibrary(tester);
    await search(tester, 'audio');
    await tester.tap(find.text('Audio Curiosity'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('consent-dialog')), findsNothing);
    expect(fetcher.calls, hasLength(1), reason: 'search only, no book fetch');
    expect(
        tester
            .widget<Text>(find.byKey(const Key('gutenberg-error')))
            .data,
        "This edition has no readable text — try another result.");
  });

  testWidgets('a search error yields a calm sentence, never a stack',
      (tester) async {
    await pumpLibrary(
        tester, handler: (u, h) => textResponse('down', status: 503));
    await search(tester, 'anything');

    expect(
        tester.widget<Text>(find.byKey(const Key('gutenberg-error'))).data,
        'The catalogue answered with an error (503).');
  });

  testWidgets('a server-supplied next-page URL is re-guarded before fetch',
      (tester) async {
    final withBadNext = jsonEncode({
      'count': 64,
      'next': 'http://192.168.1.9/books?page=2',
      'results': [
        {
          'id': 1,
          'title': 'Page One Book',
          'authors': <Map<String, Object?>>[],
          'languages': ['en'],
          'formats': {'text/plain': 'https://files.test/1.txt'},
          'download_count': 3,
        }
      ],
    });
    final fetcher = await pumpLibrary(tester,
        handler: (u, h) => textResponse(withBadNext,
            headers: {'content-type': 'application/json'}));
    await search(tester, 'one');

    await tester.tap(find.byKey(const Key('gutenberg-more')));
    await tester.pumpAndSettle();

    expect(fetcher.calls, hasLength(1),
        reason: 'the private-network next URL never reaches the wire');
    expect(
        tester.widget<Text>(find.byKey(const Key('gutenberg-error'))).data,
        "Local and private-network addresses can't be loaded.");
  });
}
