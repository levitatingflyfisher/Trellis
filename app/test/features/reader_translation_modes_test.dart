import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/reader/reader_screen.dart';

import '../support/fake_player.dart';

/// 1.5.8: a translation shows in every reading mode, not only in Page >
/// Follow along — and the reader's ⋮ chooses, per work, between Both
/// (each translated sentence under its original) and Translation only
/// (the translation in place, at reading size). Following audio under a
/// translation lights the sentence, since word timings don't cross
/// languages.
void main() {
  late AppDatabase db;
  late FakeEpisodePlayer fakePlayer;
  late PlayerController controller;
  late int profileId;
  late int workId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    fakePlayer = FakeEpisodePlayer();
    profileId = await db.profilesDao.create('Ada');
    controller = PlayerController(
        db: db, profileId: profileId, createPlayer: () => fakePlayer);
    workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'A Story',
        persistence: 'work',
        firstSeenEpochDay: 100,
        lang: 'en',
        sourceUrl: 'https://cast.test/story.mp3');
    await db.spineDao.insertSegments(workId, const [
      (idx: 0, kind: 'prose', text: 'Hello there. How are you?'),
      (idx: 1, kind: 'prose', text: 'Goodbye now.'),
    ]);
    await db.spineDao.insertAlignments(workId, const [
      (segmentIdx: 0, tStartMs: 0, tEndMs: 10000),
      (segmentIdx: 1, tStartMs: 10000, tEndMs: 20000),
    ]);
    for (final (seg, i, src, body) in const [
      (0, 0, 'Hello there.', 'Hola amiga.'),
      (0, 1, 'How are you?', '¿Cómo estás tú?'),
      (1, 0, 'Goodbye now.', 'Adiós ahora.'),
    ]) {
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: seg,
          sentenceIdx: i,
          lang: 'es',
          sourceText: src,
          body: body);
    }
    await db.spineDao.setActiveTranslationLang(workId, 'es');
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
  });

  Future<void> openIn(WidgetTester tester, String mode) async {
    final work = (await db.spineDao.workById(workId))!;
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(
            db: db, profileId: profileId, work: work, player: controller)));
    await tester.pumpAndSettle();
    if (mode == 'rsvp') {
      await tester.tap(find.byKey(const Key('mode-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('mode-item-rsvp')));
      await tester.pumpAndSettle();
      return;
    }
    await tester.tap(find.byKey(const Key('mode-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key(
        mode == 'line' ? 'highlight-item-line' : 'highlight-item-follow')));
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(const Key('reader-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  Finder rich(String text) => find.textContaining(text, findRichText: true);

  group('Both', () {
    testWidgets('RSVP shows the sentence\'s translation under the word',
        (tester) async {
      await openIn(tester, 'rsvp');
      expect(find.byKey(const Key('rsvp-translation')), findsOneWidget);
      expect(find.text('Hola amiga.'), findsOneWidget);

      // Two words on: the second sentence, and its translation.
      final rect = tester.getRect(find.byKey(const Key('reader-tapzone')));
      for (var i = 0; i < 2; i++) {
        await tester
            .tapAt(Offset(rect.left + rect.width * 5 / 6, rect.center.dy));
        await tester.pump();
      }
      expect(find.text('¿Cómo estás tú?'), findsOneWidget);
    });

    testWidgets('a translation never moves the word the eyes rest on',
        (tester) async {
      await openIn(tester, 'rsvp');
      double pivotY() =>
          tester.getCenter(find.byKey(const Key('rsvp-piv'))).dy;
      final withShort = pivotY();
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: 'es',
          sourceText: 'Hello there.',
          body: 'Hola amiga, una frase mucho más larga que ocupa varias '
              'líneas debajo de la palabra que se lee.');
      await tester.pumpWidget(const SizedBox());
      await openIn(tester, 'rsvp');
      expect(pivotY(), withShort);
    });

    testWidgets('Line shows each translation under its sentence',
        (tester) async {
      await openIn(tester, 'line');
      expect(find.byKey(const Key('translation-0-0')), findsOneWidget);
      expect(find.byKey(const Key('translation-0-1')), findsOneWidget);
      expect(find.byKey(const Key('translation-1-0')), findsOneWidget);
      expect(rich('Hello there.'), findsOneWidget);
    });

    testWidgets('Follow along keeps its interlinear lines', (tester) async {
      await openIn(tester, 'follow');
      expect(find.byKey(const Key('translation-0-1')), findsOneWidget);
      expect(find.text('Hello'), findsNothing,
          reason: 'word 0 is the drop cap; "there." is a plain word');
      expect(find.text('there.'), findsOneWidget);
    });

    testWidgets('following audio lights the translated sentence being heard',
        (tester) async {
      await controller.playWork((await db.spineDao.workById(workId))!);
      await openIn(tester, 'follow');
      fakePlayer.emitPosition(const Duration(seconds: 7)); // "How are you?"
      await tester.pump();
      expect(
          find.descendant(
              of: find.byKey(const Key('translation-lit')),
              matching: find.byKey(const Key('translation-0-1'))),
          findsOneWidget);
    });
  });

  group('Translation only', () {
    testWidgets('is a ⋮ choice, remembered for the work', (tester) async {
      await openIn(tester, 'follow');
      await choose(tester, 'translation-view-only');

      expect(find.text('amiga.'), findsOneWidget,
          reason: 'the translation flows as the page\'s own words');
      expect(find.text('there.'), findsNothing);
      expect(find.byKey(const Key('translation-0-0')), findsNothing);
      expect(await db.spineDao.translationOnly(workId), isTrue);

      // Opened again: still in translation.
      await tester.pumpWidget(const SizedBox());
      await openIn(tester, 'follow');
      expect(find.text('amiga.'), findsOneWidget);

      await choose(tester, 'translation-view-both');
      expect(find.text('there.'), findsOneWidget);
      expect(await db.spineDao.translationOnly(workId), isFalse);
    });

    testWidgets('RSVP reads the translation', (tester) async {
      await db.spineDao.setTranslationOnly(workId, true);
      await openIn(tester, 'rsvp');
      String word() => [
            for (final k in ['rsvp-bef', 'rsvp-piv', 'rsvp-aft'])
              tester.widget<Text>(find.byKey(Key(k))).data
          ].join();
      expect(word(), 'Hola');
      expect(find.byKey(const Key('rsvp-translation')), findsNothing);
    });

    testWidgets('Line reads the translation', (tester) async {
      await db.spineDao.setTranslationOnly(workId, true);
      await openIn(tester, 'line');
      expect(rich('Hola amiga. ¿Cómo estás tú?'), findsOneWidget);
      expect(rich('Hello'), findsNothing);
    });

    testWidgets('following audio lights the whole sentence, and a tap seeks '
        'to its original', (tester) async {
      await db.spineDao.setTranslationOnly(workId, true);
      await controller.playWork((await db.spineDao.workById(workId))!);
      await openIn(tester, 'follow');

      // 7s is "are", in "How are you?": the translated sentence lights.
      fakePlayer.emitPosition(const Duration(seconds: 7));
      await tester.pump();
      final cursor = find.byKey(const Key('cursor-word'));
      expect(tester.widget<Text>(cursor).data, '¿Cómo');
      expect(find.byKey(const Key('sentence-lit')), findsNWidgets(2),
          reason: 'estás and tú? light with it');

      fakePlayer.log.clear();
      await tester.tap(find.text('Adiós'));
      await tester.pumpAndSettle();
      expect(fakePlayer.log, contains('seek:10000'));
    });

    testWidgets('the saved place is the original\'s', (tester) async {
      await db.spineDao.setTranslationOnly(workId, true);
      await openIn(tester, 'follow');
      await tester.tap(find.text('estás'));
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      final pos = await db.spineDao
          .position(profileId: profileId, workId: workId);
      expect((pos!.segmentIdx, pos.wordIdx), (0, 2),
          reason: '"How", where "How are you?" starts');
    });
  });
}
