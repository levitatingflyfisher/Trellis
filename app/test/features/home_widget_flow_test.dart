import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/home_widget/home_widget_host.dart';
import 'package:trellis/features/home_widget/widget_snapshot.dart';
import 'package:trellis/features/reader/reader_screen.dart';
import 'package:trellis/features/works/work_page.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/scripted_fetcher.dart';

/// A widget host with a hand on it: taps waiting before the app is up (the
/// widget opened it) and taps arriving while it runs.
class _FakeWidget extends HomeWidgetHost {
  final waiting = <WidgetAction>[];
  final pushed = <WidgetSnapshot>[];

  @override
  bool get available => true;

  @override
  Future<void> push(WidgetSnapshot snapshot) async => pushed.add(snapshot);

  @override
  Future<List<WidgetAction>> takePending() async {
    final all = [...waiting];
    waiting.clear();
    return all;
  }

  void arrive(WidgetAction a) {
    waiting.add(a);
    onArrival?.call();
  }
}

/// The home-screen widget's taps, end to end in the app: Play resumes the
/// last-played work, Continue reading opens the reader, the art opens the
/// work page, and a tap meant for another reader does nothing.
void main() {
  late AppDatabase db;
  late _FakeWidget host;
  late FakeEpisodePlayer player;
  late int profileId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    host = _FakeWidget();
    player = FakeEpisodePlayer();
    profileId = await db.profilesDao.create('Ada');
  });
  tearDown(() => db.close());

  Future<int> seedEpisode() async {
    final feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://cast.test/feed', title: 'Show');
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Harbour episode',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/1.mp3');
    await db.feedsDao.insertEpisode(
        workId: id,
        feedId: feedId,
        guid: 'g1',
        enclosureUrl: 'https://cast.test/1.mp3',
        publishedAtMs: 1000);
    return id;
  }

  Future<int> seedText() async {
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'article',
        title: 'On hedges',
        persistence: 'kept',
        firstSeenEpochDay: 100);
    await db.spineDao.insertSegments(id, const [
      (idx: 0, kind: 'prose', text: 'A laid hedge is cut and bent.'),
      (idx: 1, kind: 'prose', text: 'It grows thick from below.'),
    ]);
    await db.spineDao.savePosition(
        profileId: profileId,
        workId: id,
        segmentIdx: 1,
        wordIdx: 0,
        lastModality: 'read');
    return id;
  }

  Future<void> boot(WidgetTester tester) async {
    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((url, _) => throw UnimplementedError()),
        createPlayer: () => player,
        homeWidget: host));
    await tester.pumpAndSettle();
  }

  testWidgets('a fresh install writes the empty card', (tester) async {
    await boot(tester);
    expect(host.pushed, isNotEmpty);
    expect(host.pushed.last.audio, isNull);
    expect(host.pushed.last.reading, isNull);
  });

  testWidgets('Play from a cold start resumes the last-played episode',
      (tester) async {
    final id = await seedEpisode();
    await db.profilesDao.recordLastPlayed(profileId, id);
    host.waiting.add(WidgetAction(WidgetActionKind.play, profileId: profileId));
    await boot(tester);
    expect(player.loadedUrl, 'https://cast.test/1.mp3');
    expect(player.playing, isTrue);
    expect(host.pushed.last.audio?.playing, isTrue);
  });

  testWidgets('Play and Pause with the app running, each doing what the '
      'card showed', (tester) async {
    final id = await seedEpisode();
    await db.profilesDao.recordLastPlayed(profileId, id);
    await boot(tester);
    host.arrive(WidgetAction(WidgetActionKind.play, profileId: profileId));
    await tester.pumpAndSettle();
    expect(player.playing, isTrue);
    host.arrive(WidgetAction(WidgetActionKind.play, profileId: profileId));
    await tester.pumpAndSettle();
    expect(player.playing, isTrue, reason: 'a second Play is not a pause');
    host.arrive(WidgetAction(WidgetActionKind.pause, profileId: profileId));
    await tester.pumpAndSettle();
    expect(player.playing, isFalse);
    expect(host.pushed.last.audio?.playing, isFalse);
    host.arrive(WidgetAction(WidgetActionKind.pause, profileId: profileId));
    await tester.pumpAndSettle();
    expect(player.playing, isFalse);
  });

  testWidgets('the skip buttons use the bar’s own 15 s back and 30 s on',
      (tester) async {
    final id = await seedEpisode();
    await db.profilesDao.recordLastPlayed(profileId, id);
    await boot(tester);
    host.arrive(WidgetAction(WidgetActionKind.play, profileId: profileId));
    await tester.pumpAndSettle();
    player.emitDuration(const Duration(minutes: 30));
    player.emitPosition(const Duration(minutes: 1));
    host.arrive(WidgetAction(WidgetActionKind.forward, profileId: profileId));
    await tester.pumpAndSettle();
    expect(player.position, const Duration(seconds: 90));
    host.arrive(WidgetAction(WidgetActionKind.back, profileId: profileId));
    await tester.pumpAndSettle();
    expect(player.position, const Duration(seconds: 75));
  });

  testWidgets('Continue reading opens the reader on that text',
      (tester) async {
    final id = await seedText();
    host.waiting.add(
        WidgetAction(WidgetActionKind.read, workId: id, profileId: profileId));
    await boot(tester);
    expect(find.byType(ReaderScreen), findsOneWidget);
    expect(host.pushed.last.reading?.title, 'On hedges');
  });

  testWidgets('the art or title opens the work page', (tester) async {
    final id = await seedEpisode();
    host.waiting.add(WidgetAction(WidgetActionKind.openWork,
        workId: id, profileId: profileId));
    await boot(tester);
    expect(find.byType(WorkPage), findsOneWidget);
  });

  testWidgets('a tap still lands while a page a tap opened is open',
      (tester) async {
    final text = await seedText();
    final ep = await seedEpisode();
    await boot(tester);
    host.arrive(WidgetAction(WidgetActionKind.read,
        workId: text, profileId: profileId));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderScreen), findsOneWidget);
    host.arrive(WidgetAction(WidgetActionKind.openWork,
        workId: ep, profileId: profileId));
    await tester.pumpAndSettle();
    expect(find.byType(WorkPage), findsOneWidget);
  });

  testWidgets('switching reader empties the card before the picker shows',
      (tester) async {
    final text = await seedText();
    await db.profilesDao.create('Blaise');
    await db.deviceSettingsDao.setLastProfileId(profileId);
    await boot(tester);
    expect(host.pushed.last.reading?.workId, text);
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-switcher')));
    await tester.pumpAndSettle();
    expect(find.text('Who’s reading?'), findsOneWidget);
    final last = host.pushed.last;
    expect(last.audio, isNull);
    expect(last.reading, isNull);
    expect(last.profileId, 0);
  });

  testWidgets('a tap meant for another reader does nothing', (tester) async {
    final id = await seedText();
    host.waiting.add(WidgetAction(WidgetActionKind.read,
        workId: id, profileId: profileId + 1));
    await boot(tester);
    expect(find.byType(ReaderScreen), findsNothing);
  });

  test('a tap parses from the channel, and junk does not', () {
    final a = WidgetAction.fromJson(
        {'kind': 'read', 'workId': 4, 'profileId': 2})!;
    expect(a.kind, WidgetActionKind.read);
    expect(a.workId, 4);
    expect(a.profileId, 2);
    expect(WidgetAction.fromJson({'kind': 'explode'}), isNull);
    expect(WidgetAction.fromJson({'kind': 'pause', 'workId': 'x'})!.workId,
        isNull);
  });
}
