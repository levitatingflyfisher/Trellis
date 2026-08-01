import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_screen.dart';

import '../support/fake_tts.dart';

/// The ticker (RSVP) under THE cursor law (ADR-0002): read, ticker and
/// speak are three renderers over ONE Position row — switching between them
/// moves zero data, and an advance made by any of them is where the others
/// pick up. Plus the ticker's own control: the wpm slider re-paces the
/// dwell and the choice holds for the session (no settings row exists in
/// the schema, so per-profile persistence is deliberately not claimed).
void main() {
  late AppDatabase db;
  late FakeTtsSpeaker tts;
  late int profileId;
  late int workId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tts = FakeTtsSpeaker();
    profileId = await db.profilesDao.create('Ada');
    workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'note',
        title: 'Nine Words',
        persistence: 'work',
        firstSeenEpochDay: 100,
        lang: 'en');
    await db.spineDao.insertSegments(workId, const [
      (idx: 0, kind: 'prose', text: 'One two three.'),
      (idx: 1, kind: 'prose', text: 'Four five six.'),
      (idx: 2, kind: 'prose', text: 'Seven eight nine.'),
    ]);
  });
  tearDown(() => db.close());

  Future<void> pumpReader(WidgetTester tester) async {
    final work = (await db.spineDao.worksOf(profileId)).single;
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(
            db: db, profileId: profileId, work: work, tts: tts)));
    await tester.pumpAndSettle();
  }

  String rsvpWord(WidgetTester tester) {
    String at(Key k) => tester.widget<Text>(find.byKey(k)).data!;
    return at(const Key('rsvp-bef')) +
        at(const Key('rsvp-piv')) +
        at(const Key('rsvp-aft'));
  }

  Future<void> stepRight(WidgetTester tester) async {
    final rect = tester.getRect(find.byKey(const Key('reader-tapzone')));
    await tester
        .tapAt(Offset(rect.left + rect.width * 5 / 6, rect.center.dy));
    await tester.pump();
  }

  /// Campaign 9 Phase 6: `mode-toggle` now opens a labeled three-way
  /// picker (Scroll / Words / Lines) rather than cycling on its own tap —
  /// [itemKey] names the destination explicitly (`mode-item-words`,
  /// `mode-item-scroll`, `mode-item-lines`).
  Future<void> switchMode(WidgetTester tester, String itemKey) async {
    await tester.tap(find.byKey(const Key('mode-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key(itemKey)));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'THE cursor law: ticker → read → ticker → speak → read all project '
      'one Position row', (tester) async {
    await pumpReader(tester);

    // Ticker: step to 'five' (segment 1, word 1).
    for (var i = 0; i < 4; i++) {
      await stepRight(tester);
    }
    expect(rsvpWord(tester), 'five');

    // → read (scroll): the same word is the cursor.
    await switchMode(tester, 'mode-item-scroll');
    expect(tester.widget<Text>(find.byKey(const Key('cursor-word'))).data,
        'five');

    // → ticker (Words) again, named explicitly rather than "toggled
    // back" — the picker is a labeled three-way choice, not a binary
    // cycle (Campaign 9 Phase 6): still 'five'.
    await switchMode(tester, 'mode-item-words');
    expect(rsvpWord(tester), 'five');

    // → speak: the voice starts at the CURSOR's segment, not the top.
    await tester.tap(find.byKey(const Key('speak-toggle')));
    await tester.pump();
    expect(tts.utterances.single.text, 'Four five six.');

    // One utterance beat: speech advances the shared cursor to segment 2.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(tts.utterances[1].text, 'Seven eight nine.');
    expect(rsvpWord(tester), 'Seven');

    // Stop the voice; → read: the place speech reached is where reading
    // resumes, and the persisted row is that same (segmentIdx, wordIdx).
    await tester.tap(find.byKey(const Key('speak-toggle')));
    await tester.pump();
    await switchMode(tester, 'mode-item-scroll');
    expect(tester.widget<Text>(find.byKey(const Key('cursor-word'))).data,
        'Seven');

    final pos =
        await db.spineDao.position(profileId: profileId, workId: workId);
    expect((pos!.segmentIdx, pos.wordIdx), (2, 0));
    expect(pos.lastModality, 'speak');
  });

  testWidgets('the wpm slider re-paces the dwell and holds for the session',
      (tester) async {
    await pumpReader(tester);

    await tester.drag(
        find.byKey(const Key('wpm-slider')), const Offset(600, 0));
    await tester.pump();
    expect(find.text('1500 wpm'), findsOneWidget);

    // At 1500 wpm a plain word dwells 40ms.
    await tester.tap(find.byKey(const Key('play-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 35));
    expect(rsvpWord(tester), 'One');
    await tester.pump(const Duration(milliseconds: 10));
    expect(rsvpWord(tester), 'two');
    await tester.tap(find.byKey(const Key('play-toggle'))); // pause
    await tester.pump();

    // The choice survives a mode round-trip (in-memory by design — the
    // schema has no settings row to persist it into). Named explicitly
    // both directions rather than "toggled back" — the picker is a
    // labeled three-way choice, not a binary cycle (Campaign 9 Phase 6).
    await switchMode(tester, 'mode-item-scroll');
    await switchMode(tester, 'mode-item-words');
    expect(find.text('1500 wpm'), findsOneWidget);
  });
}
