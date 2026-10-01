import 'dart:async';

import 'package:brain_wiring/brain_wiring.dart' show AskException, Brain;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/translation/brain_translator.dart';
import 'package:trellis/features/reader/translation/sentence_units.dart';
import 'package:trellis/features/reader/translation/marian_types.dart';
import 'package:trellis/features/reader/translation/translation_job.dart';

import '../../support/fake_brain.dart';
import '../../support/fake_sentence_translator.dart';

/// TranslationJobController (ADR-0008 "Babel" Phase 3): the cancellable,
/// resumable batch that fills in a work's TranslationSentence rows.
/// Resumability is free — the store itself is the checkpoint — so these
/// tests never touch JobsDao.
void main() {
  late AppDatabase db;
  late int workId;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final profileId = await db.profilesDao.create('Ada');
    workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'article',
        title: 'A',
        persistence: 'work',
        firstSeenEpochDay: 100);
  });
  tearDown(() => db.close());

  List<TranslatableSentence> units(List<String> texts, {int segIdx = 0}) => [
        for (var i = 0; i < texts.length; i++)
          TranslatableSentence(segIdx: segIdx, sentenceIdx: i, text: texts[i]),
      ];

  test('translates every sentence and persists each one', () async {
    final calls = <String>[];
    final controller = TranslationJobController(
      dao: db.spineDao,
      workId: workId,
      lang: 'es',
      units: units(['One.', 'Two.', 'Three.']),
      translate: (s) async {
        calls.add(s);
        return 'es:$s';
      },
    );

    await controller.start();

    expect(calls, ['One.', 'Two.', 'Three.']);
    expect(controller.state.phase, TranslationJobPhase.done);
    expect(controller.state.doneUnits, 3);
    expect(controller.state.totalUnits, 3);
    final stored = await db.spineDao.translationSentencesOf(workId, lang: 'es');
    expect(stored.length, 3);
    expect(stored[(0, 0)]!.body, 'es:One.');
    expect(stored[(0, 1)]!.body, 'es:Two.');
    expect(stored[(0, 2)]!.body, 'es:Three.');
  });

  test('stamps the engine provenance on every row it writes (Campaign 8 '
      '"Babel widens" Phase 5: default \'marian\', a caller can name a '
      'Brain instead)', () async {
    final controller = TranslationJobController(
      dao: db.spineDao,
      workId: workId,
      lang: 'es',
      units: units(['One.']),
      translate: (s) async => 'es:$s',
    );
    await controller.start();
    final stored = await db.spineDao.translationSentencesOf(workId, lang: 'es');
    expect(stored[(0, 0)]!.engine, 'marian');

    final brainController = TranslationJobController(
      dao: db.spineDao,
      workId: workId,
      lang: 'es',
      units: units(['Two.'], segIdx: 1),
      translate: (s) async => 'es:$s',
      engine: 'domovoi:stove',
    );
    await brainController.start();
    final stored2 = await db.spineDao.translationSentencesOf(workId, lang: 'es');
    expect(stored2[(1, 0)]!.engine, 'domovoi:stove');
  });

  test('a re-run skips sentences already stored for the current source '
      'text — translate() is never called for them again', () async {
    final calls = <String>[];
    Future<String> translate(String s) async {
      calls.add(s);
      return 'es:$s';
    }

    final first = TranslationJobController(
        dao: db.spineDao,
        workId: workId,
        lang: 'es',
        units: units(['One.', 'Two.']),
        translate: translate);
    await first.start();
    expect(calls, ['One.', 'Two.']);
    calls.clear();

    final second = TranslationJobController(
        dao: db.spineDao,
        workId: workId,
        lang: 'es',
        units: units(['One.', 'Two.']),
        translate: translate);
    await second.start();

    expect(calls, isEmpty, reason: 'both already stored, nothing to redo');
    expect(second.state.doneUnits, 2);
    expect(second.state.phase, TranslationJobPhase.done);
  });

  test('cancel mid-batch keeps exactly what is done — the next unit never '
      'starts', () async {
    final gate = <Completer<String>>[];
    final controller = TranslationJobController(
      dao: db.spineDao,
      workId: workId,
      lang: 'es',
      units: units(['One.', 'Two.', 'Three.', 'Four.']),
      translate: (s) {
        final c = Completer<String>();
        gate.add(c);
        return c.future;
      },
    );

    final done = controller.start();
    // Let the first sentence's translate() call be issued, then complete
    // it and the second, then cancel BEFORE the third's call is ever made
    // — cancel is checked at the top of each iteration, so setting it
    // right after the second completes means the loop never reaches
    // translate() for the third.
    await pumpEventQueue();
    gate[0].complete('es:One.');
    await pumpEventQueue();
    gate[1].complete('es:Two.');
    controller.cancel();
    await pumpEventQueue();
    await done;

    expect(controller.state.phase, TranslationJobPhase.cancelled);
    expect(controller.state.doneUnits, 2);
    expect(gate.length, 2, reason: 'the third sentence never started');
    final stored = await db.spineDao.translationSentencesOf(workId, lang: 'es');
    expect(stored.length, 2);
    expect(stored.containsKey((0, 2)), isFalse);
    expect(stored.containsKey((0, 3)), isFalse);
  });

  test('a translator throwing on one sentence stores nothing for that '
      'index and continues to the rest — the fallback law', () async {
    final controller = TranslationJobController(
      dao: db.spineDao,
      workId: workId,
      lang: 'es',
      units: units(['One.', 'Two.', 'Three.']),
      translate: (s) async {
        if (s == 'Two.') throw StateError('the model choked on this one');
        return 'es:$s';
      },
    );

    await controller.start();

    expect(controller.state.phase, TranslationJobPhase.done);
    final stored = await db.spineDao.translationSentencesOf(workId, lang: 'es');
    expect(stored.length, 2);
    expect(stored[(0, 0)]!.body, 'es:One.');
    expect(stored.containsKey((0, 1)), isFalse);
    expect(stored[(0, 2)]!.body, 'es:Three.');
  });

  test('notifies listeners as progress advances', () async {
    final phases = <TranslationJobPhase>[];
    final controller = TranslationJobController(
      dao: db.spineDao,
      workId: workId,
      lang: 'es',
      units: units(['One.', 'Two.']),
      translate: (s) async => 'es:$s',
    );
    controller.addListener(() => phases.add(controller.state.phase));

    await controller.start();

    expect(phases, isNotEmpty);
    expect(phases.last, TranslationJobPhase.done);
    expect(phases, contains(TranslationJobPhase.running));
  });

  test('an empty unit list finishes done immediately, nothing stored',
      () async {
    final controller = TranslationJobController(
      dao: db.spineDao,
      workId: workId,
      lang: 'es',
      units: const [],
      translate: (s) async => 'es:$s',
    );
    await controller.start();
    expect(controller.state.phase, TranslationJobPhase.done);
    expect(controller.state.totalUnits, 0);
    expect(controller.state.doneUnits, 0);
  });

  group('Campaign 8 "Babel widens" Phase 5: translateBatch — the '
      'chunked-request path a Brain-backed translator needs (10-20 '
      'sentences per round trip is the whole efficiency point; the '
      'existing translate: path above is UNTOUCHED and stays byte-for-'
      'byte the same when translateBatch is not set)', () {
    test('groups NOT-already-stored units into chunkSize-sized batches, '
        'one translateBatch call per chunk', () async {
      final calls = <List<String>>[];
      final controller = TranslationJobController(
        dao: db.spineDao,
        workId: workId,
        lang: 'es',
        units: units(['One.', 'Two.', 'Three.', 'Four.', 'Five.']),
        // Never called on this path — proves translateBatch takes over
        // entirely rather than falling through to the per-sentence path.
        translate: (s) async => throw StateError('must not be called'),
        translateBatch: (sentences) async {
          calls.add(sentences);
          return [for (final s in sentences) 'BRAIN:$s'];
        },
        chunkSize: 2,
        engine: 'domovoi:stove',
      );

      await controller.start();

      expect(calls, [
        ['One.', 'Two.'],
        ['Three.', 'Four.'],
        ['Five.'],
      ], reason: 'chunkSize 2 over 5 units: two full chunks, one remainder');
      final stored = await db.spineDao.translationSentencesOf(workId, lang: 'es');
      expect(stored.length, 5);
      expect(stored[(0, 0)]!.body, 'BRAIN:One.');
      expect(stored[(0, 4)]!.body, 'BRAIN:Five.');
      expect(stored[(0, 0)]!.engine, 'domovoi:stove');
      expect(controller.state.phase, TranslationJobPhase.done);
      expect(controller.state.doneUnits, 5);
    });

    test('a null entry in the batch reply fails closed for JUST that '
        'sentence — the rest of the chunk still stores', () async {
      final controller = TranslationJobController(
        dao: db.spineDao,
        workId: workId,
        lang: 'es',
        units: units(['One.', 'Two.', 'Three.']),
        translate: (s) async => throw StateError('must not be called'),
        translateBatch: (sentences) async =>
            [for (final s in sentences) s == 'Two.' ? null : 'BRAIN:$s'],
        chunkSize: 10,
      );

      await controller.start();

      final stored = await db.spineDao.translationSentencesOf(workId, lang: 'es');
      expect(stored.length, 2);
      expect(stored[(0, 0)]!.body, 'BRAIN:One.');
      expect(stored.containsKey((0, 1)), isFalse,
          reason: 'null in the reply = fall back to English for THIS one');
      expect(stored[(0, 2)]!.body, 'BRAIN:Three.');
      expect(controller.state.phase, TranslationJobPhase.done);
      expect(controller.state.doneUnits, 3);
    });

    test('a whole chunk request throwing fails closed for every sentence '
        'in THAT chunk, never the whole episode — the next chunk still '
        'runs', () async {
      final controller = TranslationJobController(
        dao: db.spineDao,
        workId: workId,
        lang: 'es',
        units: units(['One.', 'Two.', 'Three.', 'Four.']),
        translate: (s) async => throw StateError('must not be called'),
        translateBatch: (sentences) async {
          if (sentences.contains('Two.')) {
            throw StateError('the Brain choked on this chunk');
          }
          return [for (final s in sentences) 'BRAIN:$s'];
        },
        chunkSize: 2,
      );

      await controller.start();

      final stored = await db.spineDao.translationSentencesOf(workId, lang: 'es');
      expect(stored.length, 2,
          reason: 'chunk 1 (One./Two.) failed whole; chunk 2 (Three./Four.) '
              'succeeded');
      expect(stored.containsKey((0, 0)), isFalse);
      expect(stored.containsKey((0, 1)), isFalse);
      expect(stored[(0, 2)]!.body, 'BRAIN:Three.');
      expect(stored[(0, 3)]!.body, 'BRAIN:Four.');
      expect(controller.state.phase, TranslationJobPhase.done);
      expect(controller.state.doneUnits, 4,
          reason: 'every unit was PROCESSED (attempted) even though two '
              'stored nothing — the same "doneUnits counts processed, not '
              'just stored" law the per-sentence path already follows');
    });

    test('already-stored sentences are excluded from the request itself, '
        'not just from what gets (re-)written — never pay for a chunk '
        'that includes work already done', () async {
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: 'es',
          sourceText: 'One.',
          body: 'Ya traducido.');
      final calls = <List<String>>[];
      final controller = TranslationJobController(
        dao: db.spineDao,
        workId: workId,
        lang: 'es',
        units: units(['One.', 'Two.', 'Three.']),
        translate: (s) async => throw StateError('must not be called'),
        translateBatch: (sentences) async {
          calls.add(sentences);
          return [for (final s in sentences) 'BRAIN:$s'];
        },
        chunkSize: 10,
      );

      await controller.start();

      expect(calls, [
        ['Two.', 'Three.']
      ], reason: '"One." was already stored — never sent to the Brain');
      final stored = await db.spineDao.translationSentencesOf(workId, lang: 'es');
      expect(stored[(0, 0)]!.body, 'Ya traducido.',
          reason: 'untouched — the pre-existing row stands');
      expect(controller.state.doneUnits, 3);
    });

    test('cancel takes effect at a chunk boundary — a chunk already sent '
        'still lands; the next one never starts', () async {
      final gate = <Completer<List<String?>>>[];
      final controller = TranslationJobController(
        dao: db.spineDao,
        workId: workId,
        lang: 'es',
        units: units(['One.', 'Two.', 'Three.', 'Four.']),
        translate: (s) async => throw StateError('must not be called'),
        translateBatch: (sentences) {
          final c = Completer<List<String?>>();
          gate.add(c);
          return c.future;
        },
        chunkSize: 2,
      );

      final done = controller.start();
      await pumpEventQueue();
      gate[0].complete(['BRAIN:One.', 'BRAIN:Two.']);
      controller.cancel();
      await pumpEventQueue();
      await done;

      expect(controller.state.phase, TranslationJobPhase.cancelled);
      expect(gate.length, 1, reason: 'the second chunk never started');
      final stored = await db.spineDao.translationSentencesOf(workId, lang: 'es');
      expect(stored.length, 2);
      expect(stored.containsKey((0, 2)), isFalse);
      expect(stored.containsKey((0, 3)), isFalse);
    });

    test('an empty unit list never calls translateBatch, finishes done '
        'immediately', () async {
      final controller = TranslationJobController(
        dao: db.spineDao,
        workId: workId,
        lang: 'es',
        units: const [],
        translate: (s) async => throw StateError('must not be called'),
        translateBatch: (sentences) async =>
            throw StateError('must not be called'),
      );
      await controller.start();
      expect(controller.state.phase, TranslationJobPhase.done);
      expect(controller.state.totalUnits, 0);
    });
  });

  group('Campaign 8 "Babel widens" Phase 5: BrainTranslator composed '
      'with the real controller (not a manually-scripted translateBatch '
      'closure) — proves the two pieces actually plug together, not just '
      'that each satisfies its own interface in isolation', () {
    test('a full run against a scripted Brain stores every sentence, '
        'stamped with the CALLER-CHOSEN engine string', () async {
      final brain = FakeBrain(['{"translations": ["Hola.", "Adios."]}']);
      final translator = BrainTranslator(
          brain: brain,
          sourceLang: 'en',
          targetLang: 'es',
          engine: 'domovoi:byokAnthropic');
      final controller = TranslationJobController(
        dao: db.spineDao,
        workId: workId,
        lang: 'es',
        units: units(['Hello.', 'Goodbye.']),
        translate: (s) async => throw StateError('must not be called'),
        translateBatch: translator.translateBatch,
        engine: translator.engine,
      );

      await controller.start();

      expect(brain.callCount, 1,
          reason: 'both sentences fit in one chunk (default chunkSize '
              '15 >= 2) -> one Brain request for the whole run');
      final stored = await db.spineDao.translationSentencesOf(workId, lang: 'es');
      expect(stored[(0, 0)]!.body, 'Hola.');
      expect(stored[(0, 0)]!.engine, 'domovoi:byokAnthropic');
      expect(stored[(0, 1)]!.body, 'Adios.');
      expect(controller.state.phase, TranslationJobPhase.done);
    });

    test('a stove tier pinned with nothing real behind it degrades to '
        'per-sentence fallback, not a failed episode and not a dialog '
        'per chunk — the state a real user most easily lands in',
        () async {
      // UnavailableTierBrain is the REAL stand-in brainForUse() returns
      // for BrainTier.stove today (brain_store.dart) — every complete()
      // call throws AskException, unconditionally, because the stove
      // lane has no real StoveClient behind it yet.
      final stoveBrain = _AlwaysThrowsBrain();
      final translator = BrainTranslator(
          brain: stoveBrain,
          sourceLang: 'en',
          targetLang: 'es',
          engine: 'domovoi:stove');
      final controller = TranslationJobController(
        dao: db.spineDao,
        workId: workId,
        lang: 'es',
        units: units(['One.', 'Two.', 'Three.']),
        translate: (s) async => throw StateError('must not be called'),
        translateBatch: translator.translateBatch,
        engine: translator.engine,
      );

      // The whole point of this test: start() must not throw, must not
      // hang, and must reach `done` — a stove chunk failing closed is an
      // ordinary run outcome, not an exceptional one the caller has to
      // catch.
      await controller.start();

      expect(controller.state.phase, TranslationJobPhase.done);
      final stored = await db.spineDao.translationSentencesOf(workId, lang: 'es');
      expect(stored, isEmpty,
          reason: 'nothing stored for any sentence — the reader falls '
              'back to English for the whole work, exactly the same '
              'fallback law a per-sentence translate() failure already '
              'follows on the Marian path');
      expect(controller.state.doneUnits, 3,
          reason: 'every unit was still PROCESSED (attempted), matching '
              'the "doneUnits counts processed, not stored" law');
    });
  });

  group('TranslationRun (1.5.5): one or two passes, resumable after a kill',
      () {
    /// A translator a test can stop mid-sentence: [hold] makes the Nth
    /// call (0-based) never complete, the way a killed process leaves it.
    FakeSentenceTranslator translator(String tag, {int? hold}) =>
        FakeSentenceTranslator((s) => '$tag:$s', holdAt: hold);

    test('a direct run translates, writes the target, frees the model and '
        'clears the run marker', () async {
      final t = translator('de');
      final run = TranslationRun(
        dao: db.spineDao,
        workId: workId,
        units: units(['One.', 'Two.']),
        target: 'de',
        steps: [TranslationStep(lang: 'de', open: () async => t)],
      );

      await run.start();

      expect(run.state.phase, TranslationJobPhase.done);
      final stored = await db.spineDao.translationSentencesOf(workId, lang: 'de');
      expect(stored[(0, 1)]!.body, 'de:Two.');
      expect(t.disposed, isTrue, reason: 'the ONNX sessions are freed');
      expect(await db.spineDao.translationRunLang(workId), isNull);
    });

    test('via English: pass 1 writes English, pass 2 translates the '
        'English while keeping the ORIGINAL sentence as the row\'s source, '
        'one model open at a time', () async {
      final toEn = translator('en');
      final toEs = translator('es');
      final opened = <String>[];
      final run = TranslationRun(
        dao: db.spineDao,
        workId: workId,
        units: units(['Eins.', 'Zwei.']),
        target: 'es',
        steps: [
          TranslationStep(
              lang: 'en',
              open: () async {
                opened.add('de-en');
                return toEn;
              }),
          TranslationStep(
              lang: 'es',
              open: () async {
                expect(toEn.disposed, isTrue,
                    reason: 'the first leg is freed before the second opens');
                opened.add('en-es');
                return toEs;
              }),
        ],
      );
      final totals = <int>{};
      run.addListener(() => totals.add(run.state.totalUnits));

      await run.start();

      expect(opened, ['de-en', 'en-es']);
      expect(totals, {4}, reason: 'progress covers both passes');
      final es = await db.spineDao.translationSentencesOf(workId, lang: 'es');
      expect(es[(0, 0)]!.body, 'es:en:Eins.');
      expect(es[(0, 0)]!.sourceText, 'Eins.',
          reason: 'the staleness law keys off the original sentence');
      expect(toEs.disposed, isTrue);
    });

    test('a kill partway through: the marker stays, and the next run '
        'translates only what is missing', () async {
      final killed = translator('de', hold: 2); // the 3rd call never returns
      final first = TranslationRun(
        dao: db.spineDao,
        workId: workId,
        units: units(['A.', 'B.', 'C.', 'D.']),
        target: 'de',
        steps: [TranslationStep(lang: 'de', open: () async => killed)],
      );
      unawaited(first.start());
      await pumpEventQueue();
      expect(killed.calls, ['A.', 'B.', 'C.']);
      expect(await db.spineDao.translationRunLang(workId), 'de',
          reason: 'a killed run is still marked as running');

      final again = translator('de');
      final second = TranslationRun(
        dao: db.spineDao,
        workId: workId,
        units: units(['A.', 'B.', 'C.', 'D.']),
        target: 'de',
        steps: [TranslationStep(lang: 'de', open: () async => again)],
      );
      await second.start();

      expect(again.calls, ['C.', 'D.']);
      expect(second.state.phase, TranslationJobPhase.done);
      expect(
          (await db.spineDao.translationSentencesOf(workId, lang: 'de')).length,
          4);
      expect(await db.spineDao.translationRunLang(workId), isNull);
    });

    test('resuming a pivot run with pass 1 complete never opens the first '
        'model again', () async {
      for (final (i, s) in ['Eins.', 'Zwei.'].indexed) {
        await db.spineDao.upsertTranslationSentence(
            workId: workId,
            segmentIdx: 0,
            sentenceIdx: i,
            lang: 'en',
            sourceText: s,
            body: 'en:$s');
      }
      var openedFirst = false;
      final run = TranslationRun(
        dao: db.spineDao,
        workId: workId,
        units: units(['Eins.', 'Zwei.']),
        target: 'es',
        steps: [
          TranslationStep(
              lang: 'en',
              open: () async {
                openedFirst = true;
                return translator('en');
              }),
          TranslationStep(lang: 'es', open: () async => translator('es')),
        ],
      );

      await run.start();

      expect(openedFirst, isFalse);
      expect(
          (await db.spineDao.translationSentencesOf(workId, lang: 'es'))[(0, 1)]!
              .body,
          'es:en:Zwei.');
    });

    test('cancel stops at a sentence boundary, frees the model and clears '
        'the marker', () async {
      late TranslationRun run;
      final t = FakeSentenceTranslator((s) {
        if (s == 'A.') run.cancel();
        return 'de:$s';
      });
      run = TranslationRun(
        dao: db.spineDao,
        workId: workId,
        units: units(['A.', 'B.']),
        target: 'de',
        steps: [TranslationStep(lang: 'de', open: () async => t)],
      );

      await run.start();

      expect(run.state.phase, TranslationJobPhase.cancelled);
      expect(t.calls, ['A.']);
      expect(t.disposed, isTrue);
      expect(await db.spineDao.translationRunLang(workId), isNull);
    });

    test('a model that fails to start inside translate (the real lazy '
        'open) fails the run instead of skipping every sentence', () async {
      final t = FakeSentenceTranslator((_) => throw const MarianModelInitException(
          'The downloaded translator couldn’t be started.'));
      final run = TranslationRun(
        dao: db.spineDao,
        workId: workId,
        units: units(['A.', 'B.', 'C.']),
        target: 'de',
        steps: [TranslationStep(lang: 'de', open: () async => t)],
      );

      await run.start();

      expect(run.state.phase, TranslationJobPhase.failed);
      expect(t.calls, ['A.'], reason: 'it stops at the first sentence');
      expect(t.disposed, isTrue);
      expect(await db.spineDao.hasTranslationSentences(workId, lang: 'de'),
          isFalse);
      expect(await db.spineDao.translationRunLang(workId), isNull);
    });

    test('missing model files fail the run the same way', () async {
      final t = FakeSentenceTranslator(
          (_) => throw const MarianModelMissingFilesException('gone'));
      final run = TranslationRun(
        dao: db.spineDao,
        workId: workId,
        units: units(['A.']),
        target: 'de',
        steps: [TranslationStep(lang: 'de', open: () async => t)],
      );
      await run.start();
      expect(run.state.phase, TranslationJobPhase.failed);
    });

    test('a model that will not open fails the run calmly and clears the '
        'marker', () async {
      final run = TranslationRun(
        dao: db.spineDao,
        workId: workId,
        units: units(['A.']),
        target: 'de',
        steps: [TranslationStep(lang: 'de', open: () async => null)],
      );

      await run.start();

      expect(run.state.phase, TranslationJobPhase.failed);
      expect(await db.spineDao.translationRunLang(workId), isNull);
    });
  });

}

/// Stands in for `UnavailableTierBrain` (brain_wiring's real stove/
/// localStub stub) without pulling that package's full Brain/tier stack
/// into this test file — the ONLY behavior this test needs is "every
/// call throws," which is exactly what the real stub does today.
class _AlwaysThrowsBrain implements Brain {
  @override
  Future<String> complete(String prompt) async {
    throw AskException(
        'Your home desktop is not connected yet; that tier is on the '
        'roadmap. Pick another Brain in Settings for now.');
  }
}
