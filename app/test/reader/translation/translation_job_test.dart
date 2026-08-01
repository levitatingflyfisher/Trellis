import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/translation/sentence_units.dart';
import 'package:trellis/features/reader/translation/translation_job.dart';

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
        units: units(['One.', 'Two.']),
        translate: translate);
    await first.start();
    expect(calls, ['One.', 'Two.']);
    calls.clear();

    final second = TranslationJobController(
        dao: db.spineDao,
        workId: workId,
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
      units: const [],
      translate: (s) async => 'es:$s',
    );
    await controller.start();
    expect(controller.state.phase, TranslationJobPhase.done);
    expect(controller.state.totalUnits, 0);
    expect(controller.state.doneUnits, 0);
  });
}
