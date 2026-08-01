import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/karaoke_screen.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/transcribe/transcript_writer.dart'
    show encodeWordTimingBlob;
import 'package:trellis/main.dart';

import '../support/fake_player.dart';

/// The word ledger's UI half (the schema half is ledger_db_test): a
/// long-press on any word — scroll mode, RSVP, karaoke — sets it aside via
/// the ONE dao path, cleaned of surrounding punctuation; the ledger screen
/// off the reader app bar lists and removes. The collection is the user's
/// hand (ADR-0003 law 2), so every add is calm and idempotent — no counter,
/// no streak, just a snackbar naming what was kept.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<(int, int)> seed(String text, {String title = 'Five Words'}) async {
    final profileId = await db.profilesDao.create('Ada');
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'note',
        title: title,
        persistence: 'work',
        firstSeenEpochDay: 100,
        lang: 'en');
    await db.spineDao
        .insertSegments(workId, [(idx: 0, kind: 'prose', text: text)]);
    return (profileId, workId);
  }

  Future<void> openReader(WidgetTester tester,
      {String title = 'Five Words'}) async {
    await tester.pumpWidget(TrellisApp(db: db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'long-press on a scroll-mode word keeps it, cleaned, with a calm '
      'snackbar; a second long-press stays idempotent', (tester) async {
    final (profileId, workId) = await seed('One two three four five.');
    await openReader(tester);

    await tester.tap(find.byKey(const Key('mode-toggle')));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('five.'));
    await tester.pump();

    expect(find.text('“five” is in your word ledger.'), findsOneWidget);
    var rows = await db.ledgerDao.wordsOf(profileId);
    expect(rows.single.word, 'five', reason: 'edge punctuation stripped');
    expect(rows.single.lang, 'en');
    expect(rows.single.sourceWorkId, workId);

    await tester.longPress(find.text('five.'));
    await tester.pump();
    rows = await db.ledgerDao.wordsOf(profileId);
    expect(rows, hasLength(1), reason: 'the dao dedupe is the only path');
  });

  testWidgets('long-press on the RSVP word keeps the word under the cursor',
      (tester) async {
    final (profileId, _) = await seed('One two three four five.');
    await openReader(tester);

    // Step to 'two', then hold the word zone.
    final rect = tester.getRect(find.byKey(const Key('reader-tapzone')));
    await tester
        .tapAt(Offset(rect.left + rect.width * 5 / 6, rect.center.dy));
    await tester.pump();
    await tester.longPress(find.byKey(const Key('reader-tapzone')));
    await tester.pump();

    final rows = await db.ledgerDao.wordsOf(profileId);
    expect(rows.single.word, 'two');
    expect(find.text('“two” is in your word ledger.'), findsOneWidget);
  });

  testWidgets('the app bar opens the ledger; removal is a button away',
      (tester) async {
    final (profileId, _) = await seed('One two three four five.');
    final saudadeId = await db.ledgerDao
        .add(profileId: profileId, word: 'saudade', lang: 'pt', nowMs: 1000);
    final hyggeId = await db.ledgerDao
        .add(profileId: profileId, word: 'hygge', lang: 'da', nowMs: 2000);
    await openReader(tester);

    await tester.tap(find.byKey(const Key('open-ledger')));
    await tester.pumpAndSettle();
    expect(find.text('hygge'), findsOneWidget, reason: 'newest first');
    expect(find.text('saudade'), findsOneWidget);

    await tester.tap(find.byKey(Key('ledger-remove-$hyggeId')));
    await tester.pumpAndSettle();
    expect(find.text('hygge'), findsNothing);
    expect((await db.ledgerDao.wordsOf(profileId)).single.word, 'saudade');

    await tester.tap(find.byKey(Key('ledger-remove-$saudadeId')));
    await tester.pumpAndSettle();
    expect(await db.ledgerDao.wordsOf(profileId), isEmpty);
    expect(find.text('Nothing set aside yet.'), findsOneWidget,
        reason: 'the empty state is an invitation, not a void');
  });

  testWidgets('long-press on a karaoke word keeps it under the work profile',
      (tester) async {
    final profileId = await db.profilesDao.create('Ada');
    final feedId = await db.feedsDao
        .insertFeed(profileId: profileId, url: 'https://cast.test/feed');
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Ep 1',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/1.mp3',
        lang: 'pt');
    await db.feedsDao.insertEpisode(
        workId: workId,
        feedId: feedId,
        guid: 'g1',
        enclosureUrl: 'https://cast.test/1.mp3',
        publishedAtMs: 1000);
    await db.spineDao.insertSegments(
        workId, const [(idx: 0, kind: 'prose', text: 'Ola mundo.')]);
    await db.into(db.alignments).insert(AlignmentsCompanion.insert(
        workId: workId,
        segmentIdx: 0,
        tStartMs: 0,
        tEndMs: 1500,
        wordTimings: Value(encodeWordTimingBlob([
          ['Ola', 0, 700],
          ['mundo.', 700, 1500],
        ]))));
    final work =
        (await db.spineDao.worksOf(profileId)).single;
    final player = FakeEpisodePlayer();
    final controller = PlayerController(
        db: db, profileId: profileId, createPlayer: () => player);
    addTearDown(controller.dispose);
    await controller.playWork(work);
    player.emitPosition(const Duration(milliseconds: 800));

    await tester.pumpWidget(MaterialApp(
        home: KaraokeScreen(db: db, controller: controller, work: work)));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('mundo.'));
    await tester.pump();

    final rows = await db.ledgerDao.wordsOf(profileId);
    expect(rows.single.word, 'mundo', reason: 'edge punctuation stripped');
    expect(rows.single.lang, 'pt');
    expect(rows.single.sourceWorkId, work.id);
    expect(find.text('“mundo” is in your word ledger.'), findsOneWidget);
  });
}
