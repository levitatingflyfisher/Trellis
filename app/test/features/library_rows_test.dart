import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/library/library_screen.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/works/work_row.dart';

import '../support/fake_player.dart';

class _Selects extends QueryInterceptor {
  int count = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
      QueryExecutor executor, String statement, List<Object?> args) {
    count++;
    return super.runSelect(executor, statement, args);
  }
}

/// The Library in the shared row (1.5.4): the same anatomy as Latest,
/// with progress, loaded in a few queries for the whole shelf.
void main() {
  late AppDatabase db;
  late _Selects selects;
  late int profileId;

  setUp(() async {
    selects = _Selects();
    db = AppDatabase.forTesting(NativeDatabase.memory().interceptWith(selects));
    profileId = await db.profilesDao.create('Ada');
  });
  tearDown(() => db.close());

  Future<int> text(String title, {String kind = 'book'}) async {
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: kind,
        title: title,
        persistence: 'work',
        firstSeenEpochDay: 20000);
    await db.spineDao.insertSegments(id, [
      for (var i = 0; i < 4; i++)
        (idx: i, kind: 'prose', text: 'A sentence of some length here.'),
    ]);
    return id;
  }

  Future<void> pump(WidgetTester tester) async {
    final player = PlayerController(
        db: db, profileId: profileId, createPlayer: FakeEpisodePlayer.new);
    addTearDown(player.dispose);
    await tester.pumpWidget(MaterialApp(
        home: LibraryScreen(
            key: UniqueKey(),
            db: db,
            profile: (await db.profilesDao.all()).single,
            onSwitchProfile: () {},
            player: player)));
    await tester.pumpAndSettle();
  }

  testWidgets('a book is the shared row, with Read and its progress',
      (tester) async {
    final book = await text('Middlemarch');
    await db.spineDao.savePosition(
        profileId: profileId,
        workId: book,
        segmentIdx: 2,
        wordIdx: 0,
        lastModality: 'read');
    await pump(tester);

    expect(find.byType(WorkRow), findsOneWidget);
    expect(find.byKey(Key('read-$book')), findsOneWidget);
    final bar = tester
        .widget<LinearProgressIndicator>(find.byKey(Key('progress-$book')));
    expect(bar.value, 0.5);
    expect(find.textContaining('Book · '), findsOneWidget);
  });

  testWidgets('a kept, transcribed episode offers Read and says Kept',
      (tester) async {
    final feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://x.test/f', title: 'Night Sky');
    final ep = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Aurora',
        persistence: 'work',
        firstSeenEpochDay: 100);
    await db.feedsDao.insertEpisode(
        workId: ep,
        feedId: feedId,
        guid: 'g',
        enclosureUrl: 'https://x.test/a.mp3',
        publishedAtMs: DateTime(2026, 8, 5).millisecondsSinceEpoch);
    await db.spineDao
        .insertSegments(ep, const [(idx: 0, kind: 'prose', text: 'Said.')]);
    await db.spineDao.insertAlignments(
        ep, const [(segmentIdx: 0, tStartMs: 0, tEndMs: 900)]);
    await pump(tester);

    expect(find.byKey(Key('read-$ep')), findsOneWidget);
    expect(find.byKey(Key('play-$ep')), findsOneWidget);
    expect(find.text('Kept'), findsOneWidget);
    expect(find.textContaining('Night Sky · 5 Aug'), findsOneWidget);
  });

  testWidgets('a pinned work says Pinned', (tester) async {
    final book = await text('Middlemarch');
    await db.spineDao.setPinned(book, true);
    await pump(tester);
    expect(find.byKey(Key('pinned-$book')), findsOneWidget);
  });

  testWidgets('the shelf costs the same queries for 3 works as for 30',
      (tester) async {
    for (var i = 0; i < 3; i++) {
      await text('Book $i');
    }
    selects.count = 0;
    await pump(tester);
    final few = selects.count;

    for (var i = 3; i < 30; i++) {
      await text('Book $i');
    }
    selects.count = 0;
    await pump(tester);
    expect(selects.count, few);
  });
}
