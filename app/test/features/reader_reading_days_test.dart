import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/intake/paste_intake.dart' show epochDayUtcNow;
import 'package:trellis/main.dart';

/// Campaign 4 Phase 5's write side, wired into the reader: every
/// `_savePosition` call also records today's UTC epoch day in
/// [ReadingDays] (idempotent, additive — ADR-0003 law 5, no streaks). This
/// is the ONE cursor-persistence path already shared by pause, mode
/// toggle, seek and back, so nothing new triggers it.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  testWidgets('pausing the RSVP cursor records today as an active reading '
      'day', (tester) async {
    final profileId = await db.profilesDao.create('Ada');
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'note',
        title: 'Five Words',
        persistence: 'work',
        firstSeenEpochDay: 100,
        lang: 'en');
    await db.spineDao.insertSegments(workId,
        [(idx: 0, kind: 'prose', text: 'One two three four five.')]);

    await tester.pumpWidget(TrellisApp(db: db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ada'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Five Words'));
    await tester.pumpAndSettle();

    // Center tap on the RSVP tapzone: play, then pause — _pause() is one
    // of the shared _savePosition call sites.
    await tester.tap(find.byKey(const Key('reader-tapzone')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const Key('reader-tapzone')));
    await tester.pumpAndSettle();

    final rows = await (db.select(db.readingDays)
          ..where((t) => t.profileId.equals(profileId)))
        .get();
    expect(rows, hasLength(1));
    expect(rows.single.epochDay, epochDayUtcNow());
  });
}
