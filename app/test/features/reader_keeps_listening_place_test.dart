import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_screen.dart';

/// 1.5.9 review (I2): the reader and the player share one Position row.
/// A reader left open with its cursor untouched (follow off) wrote that
/// cursor back over the place the player had saved since, freshly
/// stamped, whenever the app went to the background; a kill then resumed
/// the episode where the reader had been opened.
void main() {
  late AppDatabase db;
  late int profileId;
  late Work work;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Ep 1',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/1.mp3');
    await db.spineDao.insertSegments(id, const [
      (idx: 0, kind: 'prose', text: 'First sentence.'),
      (idx: 1, kind: 'prose', text: 'Second sentence.'),
      (idx: 2, kind: 'prose', text: 'Third sentence.'),
    ]);
    // Read a minute ago.
    await db.spineDao.savePosition(
        profileId: profileId,
        workId: id,
        segmentIdx: 0,
        wordIdx: 0,
        lastModality: 'read',
        readAtMs: DateTime.now().millisecondsSinceEpoch - 60000);
    work = (await db.spineDao.worksOf(profileId)).single;
  });
  tearDown(() => db.close());

  /// The player's own save, as its periodic write lands it.
  Future<void> playerSaves(int segmentIdx) => db.spineDao.savePosition(
      profileId: profileId,
      workId: work.id,
      segmentIdx: segmentIdx,
      wordIdx: 0,
      lastModality: 'listen');

  Future<int?> savedSegment() async =>
      (await db.spineDao.position(profileId: profileId, workId: work.id))
          ?.segmentIdx;

  testWidgets('a cursor left alone never writes over the newer listening '
      'place', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(db: db, profileId: profileId, work: work)));
    await tester.pumpAndSettle();
    await playerSaves(2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(await savedSegment(), 2);
    // Leaving the reader doesn't either.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(await savedSegment(), 2);
  });

  testWidgets('a cursor moved after the player saved still wins',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(db: db, profileId: profileId, work: work)));
    await tester.pumpAndSettle();
    await playerSaves(2);
    await tester.tap(find.byKey(const Key('mode-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mode-item-page')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second'));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(await savedSegment(), 1);
  });
}
