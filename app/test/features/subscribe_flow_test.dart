import 'package:comms_core/comms_core.dart';
import 'package:flutter/material.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/scripted_fetcher.dart';

const _rss = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel>
  <title>The Night Sky Cast</title>
  <item>
    <title>Aurora season</title>
    <link>https://cast.test/aurora</link>
    <pubDate>Wed, 05 Aug 2026 12:00:00 GMT</pubDate>
    <description>Lights in the north.</description>
    <enclosure url="https://cast.test/aurora.mp3" type="audio/mpeg"/>
  </item>
</channel></rss>
''';

/// Subscribe-by-URL end to end through the UI: discovery + fetch + parse
/// happen behind comms_core with a scripted fetcher — no network in tests.
void main() {
  late AppDatabase db;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.profilesDao.create('Ada');
  });
  tearDown(() => db.close());

  Future<void> pumpToSubscribe(
      WidgetTester tester, ScriptedFetcher fetcher) async {
    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: fetcher,
        createPlayer: () => FakeEpisodePlayer()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('River'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Follow a feed'));
    await tester.pumpAndSettle();
  }

  testWidgets('a feed URL lands its items in the river', (tester) async {
    final fetcher = ScriptedFetcher((u, h) => textResponse(_rss));
    await pumpToSubscribe(tester, fetcher);

    await tester.enterText(
        find.byKey(const Key('subscribe-url')), 'https://cast.test/feed');
    await tester.tap(find.byKey(const Key('subscribe-submit')));
    await tester.pumpAndSettle();

    // Back on the river with the new episode visible.
    expect(find.text('Aurora season'), findsOneWidget);
    expect(find.textContaining('The Night Sky Cast'), findsOneWidget);
  });

  testWidgets('an unreachable address shows a calm inline error and keeps '
      'the input', (tester) async {
    final fetcher =
        ScriptedFetcher((u, h) => throw Exception('connection refused'));
    await pumpToSubscribe(tester, fetcher);

    await tester.enterText(
        find.byKey(const Key('subscribe-url')), 'https://down.test/feed');
    await tester.tap(find.byKey(const Key('subscribe-submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('subscribe-error')), findsOneWidget);
    expect(find.text('https://down.test/feed'), findsOneWidget,
        reason: 'the typed address survives for correction');
  });

  testWidgets('a typed transport refusal shows its own sentence — the web '
      "fetcher's browser-blocked explanation must reach the screen",
      (tester) async {
    const honest = 'The browser blocked this fetch — sites must allow '
        "web pages to read them, and most don't.";
    final fetcher = ScriptedFetcher(
        (u, h) => throw const FetchFailedException(honest));
    await pumpToSubscribe(tester, fetcher);

    await tester.enterText(
        find.byKey(const Key('subscribe-url')), 'https://blog.test/feed');
    await tester.tap(find.byKey(const Key('subscribe-submit')));
    await tester.pumpAndSettle();

    expect(find.text(honest), findsOneWidget,
        reason: 'an explained refusal must not collapse into the generic '
            '"couldn\'t be reached as a feed" sentence');
  });

  testWidgets('a private-network address is refused by the guard',
      (tester) async {
    final fetcher = ScriptedFetcher((u, h) => textResponse(_rss));
    await pumpToSubscribe(tester, fetcher);

    await tester.enterText(
        find.byKey(const Key('subscribe-url')), 'http://192.168.1.10/feed');
    await tester.tap(find.byKey(const Key('subscribe-submit')));
    await tester.pumpAndSettle();

    expect(find.textContaining("Local and private-network"), findsOneWidget);
    expect(fetcher.calls, isEmpty);
  });

  testWidgets('following a feed twice says so instead of duplicating',
      (tester) async {
    final fetcher = ScriptedFetcher((u, h) => textResponse(_rss));
    // Pre-existing subscription.
    final profileId = (await db.profilesDao.all()).single.id;
    await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://cast.test/feed');

    await pumpToSubscribe(tester, fetcher);
    await tester.enterText(
        find.byKey(const Key('subscribe-url')), 'https://cast.test/feed');
    await tester.tap(find.byKey(const Key('subscribe-submit')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Already following'), findsOneWidget);
    expect(await db.feedsDao.feedsOf(profileId), hasLength(1));
  });
}
