import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_screen.dart';
import 'package:trellis/features/reader/translation/marian_engine.dart';

import '../support/fake_marian_translator.dart';

/// The "Translate to Spanish" batch action, wired into the reader (ADR-0008
/// "Babel" Phase 3): the model gate, the cancellable/resumable run, and the
/// "Show Spanish" toggle it unlocks. Speak-in-Spanish and the scroll-mode
/// dual display are covered in their own test files.
void main() {
  late Directory dir;
  late AppDatabase db;
  late int profileId;
  late int workId;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('trellis-reader-translate');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'article',
        title: 'A Story',
        persistence: 'work',
        firstSeenEpochDay: 100,
        lang: 'en');
    await db.spineDao.insertSegments(workId, const [
      (idx: 0, kind: 'prose', text: 'Hello there. How are you?'),
      (idx: 1, kind: 'prose', text: 'Goodbye now.'),
    ]);
  });
  tearDown(() {
    db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> pumpReader(WidgetTester tester,
      {Future<MarianTranslator?> Function()? resolveTranslator}) async {
    final work =
        (await db.spineDao.worksOf(profileId)).firstWhere((w) => w.id == workId);
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(
            db: db,
            profileId: profileId,
            work: work,
            resolveTranslator: resolveTranslator)));
    await tester.pumpAndSettle();
  }

  Future<void> openOverflow(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('reader-overflow')));
    await tester.pumpAndSettle();
  }

  group('the model gate', () {
    testWidgets('no resolveTranslator at all: no Translate action ever '
        'offered', (tester) async {
      await pumpReader(tester);
      await openOverflow(tester);
      expect(find.byKey(const Key('translate-to-spanish')), findsNothing);
    });

    testWidgets('resolveTranslator resolving to null (model not '
        'downloaded): no Translate action', (tester) async {
      await pumpReader(tester, resolveTranslator: () async => null);
      await openOverflow(tester);
      expect(find.byKey(const Key('translate-to-spanish')), findsNothing);
    });

    testWidgets('a resolved translator offers the action', (tester) async {
      await pumpReader(tester,
          resolveTranslator: () async => fakeMarianTranslator(dir));
      await openOverflow(tester);
      expect(find.byKey(const Key('translate-to-spanish')), findsOneWidget);
    });
  });

  group('running the batch', () {
    testWidgets('tapping Translate runs to completion, persists every '
        'sentence, and shows a calm progress card meanwhile', (tester) async {
      final gate = <Completer<String>>[];
      final handle = _GatedHandle(gate);
      final gatedTranslator = MarianTranslator(
        files: fakeMarianTranslatorFiles(dir),
        openHandle: (_) async => handle,
      );

      await pumpReader(tester,
          resolveTranslator: () async => gatedTranslator);
      await openOverflow(tester);
      await tester.tap(find.byKey(const Key('translate-to-spanish')));
      await tester.pump(); // starts the batch; first translate() call issued
      await tester.pump();

      expect(find.byKey(const Key('translation-progress')), findsOneWidget);

      gate[0].complete('ES: Hello there.');
      await tester.pump();
      await tester.pump();
      gate[1].complete('ES: How are you?');
      await tester.pump();
      await tester.pump();
      gate[2].complete('ES: Goodbye now.');
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('translation-progress')), findsNothing,
          reason: 'the card clears once the run is done');

      final stored = await db.spineDao.translationSentencesOf(workId, lang: 'es');
      expect(stored.length, 3);
      expect(stored[(0, 0)]!.body, 'ES: Hello there.');
      expect(stored[(0, 1)]!.body, 'ES: How are you?');
      expect(stored[(1, 0)]!.body, 'ES: Goodbye now.');
    });

    testWidgets('cancel keeps what is done and clears the progress card',
        (tester) async {
      final gate = <Completer<String>>[];
      final handle = _GatedHandle(gate);
      final translator = MarianTranslator(
        files: fakeMarianTranslatorFiles(dir),
        openHandle: (_) async => handle,
      );

      await pumpReader(tester, resolveTranslator: () async => translator);
      await openOverflow(tester);
      await tester.tap(find.byKey(const Key('translate-to-spanish')));
      await tester.pump();
      await tester.pump();

      // Cancel is checked at the top of each iteration — a sentence
      // already in flight still finishes; only the NEXT one never starts.
      // Complete the first, cancel while the second is in flight, then let
      // the second land: the batch stops before ever calling translate()
      // for the third.
      gate[0].complete('ES: Hello there.');
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('translation-cancel')), findsOneWidget);
      await tester.tap(find.byKey(const Key('translation-cancel')));
      await tester.pump();
      gate[1].complete('ES: How are you?');
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('translation-progress')), findsNothing);
      final stored = await db.spineDao.translationSentencesOf(workId, lang: 'es');
      expect(stored.length, 2);
      expect(stored.containsKey((0, 0)), isTrue);
      expect(stored.containsKey((0, 1)), isTrue);
      expect(stored.containsKey((1, 0)), isFalse,
          reason: 'the third sentence never started');
      expect(gate.length, 2, reason: 'translate() was never called a third time');
    });
  });

  group('Show Spanish', () {
    testWidgets('the toggle is absent until the work has ANY stored '
        'translation', (tester) async {
      await pumpReader(tester,
          resolveTranslator: () async => fakeMarianTranslator(dir));
      await openOverflow(tester);
      expect(find.byKey(const Key('show-spanish-toggle')), findsNothing);
    });

    testWidgets('once translations exist, the toggle appears and persists '
        'through the DAO', (tester) async {
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: 'es',
          sourceText: 'Hello there.',
          body: 'Hola.');
      await pumpReader(tester);
      await openOverflow(tester);
      expect(find.byKey(const Key('show-spanish-toggle')), findsOneWidget);

      await tester.tap(find.byKey(const Key('show-spanish-toggle')));
      await tester.pumpAndSettle();

      expect(await db.spineDao.showTranslationLayer(workId), isTrue);
    });
  });
}

/// A translator whose translate() suspends on a per-call Completer, so a
/// test can watch the batch mid-run and control exactly how many
/// sentences complete before cancelling.
class _GatedHandle implements MarianModelHandle {
  final List<Completer<String>> gate;
  _GatedHandle(this.gate);

  @override
  Future<String> translate(String sentence) {
    final c = Completer<String>();
    gate.add(c);
    return c.future;
  }

  @override
  Future<void> dispose() async {}
}
