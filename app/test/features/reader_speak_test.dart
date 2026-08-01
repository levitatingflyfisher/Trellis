import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_screen.dart';

import '../support/fake_tts.dart';

/// Speak mode: the reader reads the CURRENT segment aloud through the
/// TtsSpeaker seam and advances the spine cursor segment-by-segment — the
/// Position row updates as it advances (ADR-0002), and what is spoken is
/// whichever layer the reader is showing. The fake completes each utterance
/// on a 100ms fake-time beat, so tests drive speech with explicit pumps
/// (the timer-paced-pipeline law).
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
        title: 'Fado',
        persistence: 'work',
        firstSeenEpochDay: 100,
        lang: 'pt');
    await db.spineDao.insertSegments(workId, const [
      (idx: 0, kind: 'prose', text: 'Ola mundo.'),
      (idx: 1, kind: 'prose', text: 'Tudo bem hoje.'),
      (idx: 2, kind: 'prose', text: 'Ate logo.'),
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

  Future<Position?> savedPosition() =>
      db.spineDao.position(profileId: profileId, workId: workId);

  String rsvpWord(WidgetTester tester) {
    String at(Key k) => tester.widget<Text>(find.byKey(k)).data!;
    return at(const Key('rsvp-bef')) +
        at(const Key('rsvp-piv')) +
        at(const Key('rsvp-aft'));
  }

  testWidgets('the speak toggle reads the current segment in the work\'s '
      'language', (tester) async {
    await pumpReader(tester);

    await tester.tap(find.byKey(const Key('speak-toggle')));
    await tester.pump();

    expect(tts.utterances, [(text: 'Ola mundo.', lang: 'pt')]);
  });

  testWidgets('speech advances segment-by-segment; the Position row updates '
      'as it advances and speaking ends at the last segment',
      (tester) async {
    await pumpReader(tester);
    await tester.tap(find.byKey(const Key('speak-toggle')));
    await tester.pump();
    expect(tts.utterances, hasLength(1));

    // First utterance completes on its 100ms beat → cursor advances to
    // segment 1 and its row is saved before segment 1 is spoken.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(tts.utterances, hasLength(2));
    expect(tts.utterances[1].text, 'Tudo bem hoje.');
    expect(rsvpWord(tester), 'Tudo', reason: 'the cursor moved with speech');
    var pos = await savedPosition();
    expect((pos!.segmentIdx, pos.wordIdx), (1, 0));
    expect(pos.lastModality, 'speak');

    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(tts.utterances, hasLength(3));
    expect(tts.utterances[2].text, 'Ate logo.');

    // The last utterance ends the run: no more speech, toggle at rest.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(tts.utterances, hasLength(3));
    pos = await savedPosition();
    expect(pos!.segmentIdx, 2);
    expect(tester
        .widget<IconButton>(find.byKey(const Key('speak-toggle')))
        .isSelected, isFalse);
  });

  testWidgets('speech reads the layer the reader is showing',
      (tester) async {
    await db.spineDao.insertLayers(workId, const [
      (segmentIdx: 0, lang: 'en', kind: 'mt', text: 'Hello world.'),
      (segmentIdx: 1, lang: 'en', kind: 'mt', text: 'All well today.'),
      (segmentIdx: 2, lang: 'en', kind: 'mt', text: 'See you soon.'),
    ]);
    await pumpReader(tester);

    await tester.tap(find.byKey(const Key('lang-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('speak-toggle')));
    await tester.pump();

    expect(tts.utterances, [(text: 'Hello world.', lang: 'en')]);
  });

  testWidgets('toggling again stops the engine and keeps the place',
      (tester) async {
    await pumpReader(tester);
    await tester.tap(find.byKey(const Key('speak-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(); // segment 1 speaking

    await tester.tap(find.byKey(const Key('speak-toggle')));
    await tester.pump();
    expect(tts.stops, greaterThanOrEqualTo(1));

    // No further beats produce speech; the cursor stays where speech left it.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(tts.utterances, hasLength(2));
    expect(rsvpWord(tester), 'Tudo');
    final pos = await savedPosition();
    expect(pos!.segmentIdx, 1);
  });

  testWidgets('the ticker and speech never advance the cursor together',
      (tester) async {
    await pumpReader(tester);

    // Speaking, then pressing play: speech stops, the ticker paces.
    await tester.tap(find.byKey(const Key('speak-toggle')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('play-toggle')));
    await tester.pump();
    expect(tts.stops, greaterThanOrEqualTo(1));
    final spoken = tts.utterances.length;
    await tester.pump(const Duration(milliseconds: 200)); // 300wpm dwell
    await tester.pump();
    expect(rsvpWord(tester), 'mundo.', reason: 'the ticker advanced');
    expect(tts.utterances, hasLength(spoken), reason: 'speech stayed quiet');

    // Ticking, then toggling speak: the ticker pauses, speech leads.
    await tester.tap(find.byKey(const Key('speak-toggle')));
    await tester.pump();
    expect(
        tester
            .widget<IconButton>(find.byKey(const Key('play-toggle')))
            .tooltip,
        'Play',
        reason: 'starting speech paused the ticker');
    expect(tts.utterances.length, greaterThan(spoken));

    await tester.tap(find.byKey(const Key('speak-toggle')));
    await tester.pump();
  });

  group('sentences are the unit of speech, not whole paragraphs', () {
    // A single block carrying TWO sentences: the long-utterance stall this
    // campaign exists to fix comes from handing a whole paragraph to the
    // engine in one call. Speak mode must tick sentence-by-sentence WITHIN
    // a block, not just block-by-block.
    late int multiWorkId;

    setUp(() async {
      multiWorkId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'note',
          title: 'Duas frases',
          persistence: 'work',
          firstSeenEpochDay: 100,
          lang: 'pt');
      await db.spineDao.insertSegments(multiWorkId, const [
        (idx: 0, kind: 'prose', text: 'Ola mundo. Tudo bem hoje.'),
        (idx: 1, kind: 'prose', text: 'Ate logo.'),
      ]);
    });

    Future<void> pumpMultiReader(WidgetTester tester) async {
      final work = (await db.spineDao.worksOf(profileId))
          .firstWhere((w) => w.id == multiWorkId);
      await tester.pumpWidget(MaterialApp(
          home: ReaderScreen(
              db: db, profileId: profileId, work: work, tts: tts)));
      await tester.pumpAndSettle();
    }

    Future<Position?> multiSavedPosition() => db.spineDao
        .position(profileId: profileId, workId: multiWorkId);

    testWidgets(
        'a two-sentence block speaks one sentence at a time, not the whole '
        'paragraph in one call', (tester) async {
      await pumpMultiReader(tester);

      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();
      expect(tts.utterances, [(text: 'Ola mundo.', lang: 'pt')]);

      // The first sentence's utterance completes; the SECOND sentence of
      // the SAME block is spoken next — the block-level speak loop never
      // advances to segment 1 yet.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(tts.utterances, hasLength(2));
      expect(tts.utterances[1], (text: 'Tudo bem hoje.', lang: 'pt'));
      // The cursor moved to the SECOND sentence's first word within the
      // SAME segment — the position row is (segmentIdx, wordIdx-in-block),
      // never a segment-only granularity now.
      var pos = await multiSavedPosition();
      expect((pos!.segmentIdx, pos.wordIdx), (0, 2));

      // Only after both sentences of block 0 are spoken does the loop
      // cross into block 1.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(tts.utterances, hasLength(3));
      expect(tts.utterances[2], (text: 'Ate logo.', lang: 'pt'));
      pos = await multiSavedPosition();
      expect((pos!.segmentIdx, pos.wordIdx), (1, 0));
    });
  });

  group('the neural-voice hint (ADR-0006 speak-mode door honesty)', () {
    Future<void> pumpReaderOffering(WidgetTester tester,
        {required bool offer}) async {
      final work = (await db.spineDao.worksOf(profileId)).single;
      await tester.pumpWidget(MaterialApp(
          home: ReaderScreen(
              db: db,
              profileId: profileId,
              work: work,
              tts: tts,
              offerNeuralVoice: offer)));
      await tester.pumpAndSettle();
    }

    testWidgets('starting speech with no voice downloaded shows one quiet '
        'line, once — never a repeated nag', (tester) async {
      await pumpReaderOffering(tester, offer: true);

      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();
      expect(find.textContaining('Models'), findsOneWidget);
      // Dismiss it explicitly (rather than fighting the real SnackBar
      // timer/animation in a pumped test) so the check below is about the
      // widget's OWN nag-guard, not a banner still on screen from before.
      ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first))
          .hideCurrentSnackBar();
      await tester.pumpAndSettle();
      expect(find.textContaining('Models'), findsNothing,
          reason: 'sanity: the dismiss actually cleared it');

      // Stop and start again: the hint does not repeat (ADR-0003 law 5 —
      // no nagging).
      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();
      expect(find.textContaining('Models'), findsNothing);
    });

    testWidgets('a voice already available (or offered=false) shows nothing',
        (tester) async {
      await pumpReaderOffering(tester, offer: false);

      await tester.tap(find.byKey(const Key('speak-toggle')));
      await tester.pump();
      expect(find.textContaining('Models'), findsNothing);
    });
  });
}
