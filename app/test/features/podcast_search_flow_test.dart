import 'dart:async';
import 'dart:convert';

import 'package:comms_core/comms_core.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/scripted_fetcher.dart';

/// iTunes podcast search: a door beside subscribe-by-URL; the screen names
/// itunes.apple.com plainly and nothing fires before type + submit (the
/// gesture); results are text only (no artwork is ever fetched); picking a
/// result runs the EXISTING subscribe-by-URL path on its feedUrl.
void main() {
  late AppDatabase db;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.profilesDao.create('Ada');
  });
  tearDown(() => db.close());

  const feedUrl = 'https://cast.test/quiet-feed.xml';

  final searchJson = jsonEncode({
    'resultCount': 2,
    'results': [
      {
        'wrapperType': 'track',
        'kind': 'podcast',
        'artistName': 'The Garden Shed',
        'collectionName': 'Quiet Hours',
        'feedUrl': feedUrl,
        'artworkUrl100': 'https://is1-ssl.mzstatic.com/image/q.jpg',
      },
      {
        'wrapperType': 'track',
        'kind': 'podcast',
        'artistName': 'Someone Else',
        'collectionName': 'Loud Minutes',
        'feedUrl': 'https://cast.test/loud.xml',
        'artworkUrl100': 'https://is1-ssl.mzstatic.com/image/l.jpg',
      },
    ],
  });

  const rss = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel>
  <title>Quiet Hours</title>
  <item>
    <title>On mulch</title>
    <link>https://cast.test/mulch</link>
    <pubDate>Wed, 05 Aug 2026 12:00:00 GMT</pubDate>
    <enclosure url="https://cast.test/mulch.mp3" type="audio/mpeg"/>
  </item>
</channel></rss>
''';

  FetchResponse route(Uri u, Map<String, String>? h) {
    if (u.host == 'itunes.apple.com') {
      return textResponse(searchJson,
          headers: {'content-type': 'application/json'});
    }
    if (u.toString() == feedUrl) return textResponse(rss);
    return textResponse('lost', status: 404);
  }

  Future<ScriptedFetcher> pumpToSubscribe(WidgetTester tester,
      {FutureOr<FetchResponse> Function(Uri, Map<String, String>?)?
          handler}) async {
    final fetcher = ScriptedFetcher(handler ?? route);
    await tester.pumpWidget(TrellisApp(
        db: db, fetcher: fetcher, createPlayer: () => FakeEpisodePlayer()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('River'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Follow a feed'));
    await tester.pumpAndSettle();
    return fetcher;
  }

  Future<void> openSearchAndSubmit(WidgetTester tester, String term) async {
    await tester.tap(find.text('Search podcasts'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('podcast-search-field')), term);
    await tester.tap(find.byKey(const Key('podcast-search-submit')));
    await tester.pumpAndSettle();
  }

  testWidgets('the subscribe flow offers Search podcasts beside the URL box, '
      'the screen names its endpoint, and nothing fires before submit',
      (tester) async {
    final fetcher = await pumpToSubscribe(tester);

    // Beside subscribe-by-URL: both doors on one screen.
    expect(find.byKey(const Key('subscribe-url')), findsOneWidget);
    expect(find.text('Search podcasts'), findsOneWidget);

    await tester.tap(find.text('Search podcasts'));
    await tester.pumpAndSettle();

    expect(find.textContaining('itunes.apple.com'), findsOneWidget,
        reason: 'the endpoint is stated plainly on the screen');
    expect(fetcher.calls, isEmpty,
        reason: 'opening the screen fires nothing; type + submit is '
            'the gesture');
  });

  testWidgets('type + submit searches itunes.apple.com once and lists text '
      'results with no artwork fetched', (tester) async {
    final fetcher = await pumpToSubscribe(tester);
    await openSearchAndSubmit(tester, 'quiet hours');

    final call = fetcher.calls.single;
    expect(call.url.host, 'itunes.apple.com');
    expect(call.url.path, '/search');
    expect(call.url.queryParameters['media'], 'podcast');
    expect(call.url.queryParameters['term'], 'quiet hours');

    expect(find.text('Quiet Hours'), findsOneWidget);
    expect(find.text('The Garden Shed'), findsOneWidget);
    expect(find.byType(Image), findsNothing,
        reason: 'text results only — artwork URLs are never fetched');
  });

  testWidgets('picking a result runs the existing subscribe-by-URL path on '
      'its feedUrl and lands the feed in the river', (tester) async {
    final fetcher = await pumpToSubscribe(tester);
    await openSearchAndSubmit(tester, 'quiet hours');

    await tester.tap(find.text('Quiet Hours'));
    await tester.pumpAndSettle();

    // The feed fetch went to the feedUrl through the normal door.
    expect(fetcher.calls.map((c) => c.url.toString()), contains(feedUrl));

    final profileId = (await db.profilesDao.all()).single.id;
    final feed = (await db.feedsDao.feedsOf(profileId)).single;
    expect(feed.url, feedUrl);
    expect(feed.title, 'Quiet Hours');

    // Popped all the way back to the river with the episode visible.
    expect(find.text('On mulch'), findsOneWidget);
  });

  testWidgets('a podcast already followed says so instead of duplicating',
      (tester) async {
    final profileId = (await db.profilesDao.all()).single.id;
    await db.feedsDao.insertFeed(profileId: profileId, url: feedUrl);

    await pumpToSubscribe(tester);
    await openSearchAndSubmit(tester, 'quiet hours');
    await tester.tap(find.text('Quiet Hours'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Already following'), findsOneWidget);
    expect(await db.feedsDao.feedsOf(profileId), hasLength(1));
  });

  testWidgets('a directory error yields a calm sentence, never a stack',
      (tester) async {
    await pumpToSubscribe(tester,
        handler: (u, h) => textResponse('down', status: 500));
    await openSearchAndSubmit(tester, 'anything');

    expect(
        tester
            .widget<Text>(find.byKey(const Key('podcast-search-error')))
            .data,
        'The directory answered with an error (500).');
  });

  testWidgets('no results is a calm empty message', (tester) async {
    await pumpToSubscribe(tester,
        handler: (u, h) => textResponse(
            jsonEncode({'resultCount': 0, 'results': <Object?>[]}),
            headers: {'content-type': 'application/json'}));
    await openSearchAndSubmit(tester, 'zzzz');

    expect(find.textContaining('No podcasts matched'), findsOneWidget);
  });
}
