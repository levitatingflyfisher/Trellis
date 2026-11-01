import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart'
    show BooleanExpressionOperators, TableUpdateQuery, Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jobs_core/jobs_core.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/db/search_index.dart' show segmentRowidStride;
import 'package:trellis/features/models/models_screen.dart';
import 'package:trellis/features/reader/translation/sentence_units.dart';
import 'package:trellis/features/reader/translation/translation_job.dart';
import 'package:trellis/features/reader/translation/translator.dart';
import 'package:trellis/features/storage/recently_deleted.dart';
import 'package:trellis/features/storage/storage_by_item_screen.dart';
import 'package:trellis/features/storage/work_storage.dart';
import 'package:trellis/features/transcribe/transcribe_coordinator.dart'
    show translateJobId;
import 'package:trellis/services/device_services.dart';

import '../../support/fake_services.dart';

/// 1.5.9: a deleted transcript or translation waits 30 days in Recently
/// deleted (the fleet delete ruling: a lasting way back, not a snackbar).
void main() {
  late Directory dir;
  late AppDatabase db;
  late DeviceServices services;
  late RecentlyDeleted bin;
  late int profile;
  late int workId;
  final timings = Uint8List.fromList([1, 2, 3, 250]);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('trellis-recently-deleted');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    services = testServices(dir);
    bin = services.recentlyDeleted!;
    profile = await db.profilesDao.create('Ada');
    final feed = await db.feedsDao
        .insertFeed(profileId: profile, url: 'https://c.test/f', title: 'C');
    workId = await db.spineDao.insertWork(
        profileId: profile,
        kind: 'episode',
        title: 'Lighthouse',
        persistence: 'work',
        firstSeenEpochDay: 1);
    await db.feedsDao.insertEpisode(
        workId: workId,
        feedId: feed,
        guid: 'g',
        enclosureUrl: 'https://c.test/1.mp3',
        publishedAtMs: 1);
    await db.spineDao.insertSegments(workId, const [
      (idx: 0, kind: 'prose', text: 'The lighthouse keeper.'),
      (idx: 1, kind: 'prose', text: 'He climbs the stairs.'),
    ]);
    await db.spineDao.insertAlignments(workId, const [
      (segmentIdx: 0, tStartMs: 0, tEndMs: 1000),
      (segmentIdx: 1, tStartMs: 1000, tEndMs: 2000),
    ]);
    await (db.update(db.alignments)
          ..where((a) => a.workId.equals(workId) & a.segmentIdx.equals(0)))
        .write(AlignmentsCompanion(wordTimings: Value(timings)));
    await db.spineDao.insertLayers(workId, const [
      (segmentIdx: 0, lang: 'fr', kind: 'transcript', text: 'Le gardien.'),
      (segmentIdx: 0, lang: 'en', kind: 'mt', text: 'The keeper.'),
    ]);
    for (final lang in ['de', 'ru']) {
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 0,
          sentenceIdx: 0,
          lang: lang,
          sourceText: 'The lighthouse keeper.',
          body: '$lang: keeper');
    }
    await db.spineDao.savePosition(
        profileId: profile,
        workId: workId,
        segmentIdx: 1,
        wordIdx: 3,
        lastModality: 'read');
    await db.spineDao.setActiveTranslationLang(workId, 'ru');
    await db.spineDao.setReadLang(workId, 'ru');
    await db.spineDao.setTranslationOnly(workId, true);
    await db.into(db.captures).insert(CapturesCompanion.insert(
        profileId: profile,
        workId: workId,
        positionMs: 500,
        createdAtMs: 1,
        segmentIdx: const Value(0)));
  });
  tearDown(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<int> count(String table) async => (await db
          .customSelect('SELECT count(*) AS n FROM $table')
          .getSingle())
      .read<int>('n');

  Future<Map<String, int>> counts() async => {
        for (final t in const [
          'segments',
          'alignments',
          'layers',
          'translation_sentences',
          'positions',
        ])
          t: await count(t),
      };

  /// Every row the transcript delete touches, value for value, in a
  /// stable order: the lossless check compares these, not counts.
  Future<Map<String, List<Map<String, Object?>>>> everyRow() async {
    Future<List<Map<String, Object?>>> rows(String sql) async {
      final out = [
        for (final r in await db.customSelect(sql,
                variables: [Variable.withInt(workId)]).get())
          Map.of(r.data),
      ];
      out.sort((a, b) => a.toString().compareTo(b.toString()));
      return out;
    }

    return {
      for (final t in const [
        'segments',
        'alignments',
        'layers',
        'translation_sentences',
        'positions',
        'captures',
      ])
        t: await rows('SELECT * FROM $t WHERE work_id = ?'),
      'works': await rows('SELECT * FROM works WHERE id = ?'),
    };
  }

  Future<List<(int, int)>> ftsHits(String word) async => [
        for (final r in await db.customSelect(
                'SELECT rowid / $segmentRowidStride AS w, '
                'rowid % $segmentRowidStride AS i FROM segments_fts '
                'WHERE segments_fts MATCH ?',
                variables: [Variable.withString(word)]).get())
          (r.read<int>('w'), r.read<int>('i')),
      ];

  Future<WorkStorage> stored() async =>
      (await loadWorkStorage(db, onlyWorkId: workId)).single;

  StoredPart partOf(WorkStorage w, StoredKind kind, [String? lang]) =>
      w.parts.firstWhere((p) => p.kind == kind && p.lang == lang);

  Future<String> delete(StoredKind kind, [String? lang]) async {
    final w = await stored();
    return deletePart(w, partOf(w, kind, lang), db: db, services: services);
  }

  group('restore', () {
    test(
        'delete transcript then restore brings back segments, alignments, '
        'translations and reading place', () async {
      final before = await counts();
      final rowsBefore = await everyRow();
      expect(await ftsHits('lighthouse'), isNotEmpty);
      final message = await delete(StoredKind.transcript);
      expect(message, 'Deleted the transcript. Restore it from Recently '
          'deleted.');
      expect(await count('segments'), 0);

      final snaps = await bin.list();
      expect(snaps, hasLength(1));
      expect(snaps.single.workTitle, 'Lighthouse');
      expect(snaps.single.kind, StoredKind.transcript);
      expect(snaps.single.bytes, greaterThan(0));

      expect(await ftsHits('lighthouse'), isEmpty);
      final said = await restoreDeleted(db, bin, snaps.single);
      expect(said, 'Restored the transcript of “Lighthouse”.');
      expect(await counts(), before);
      final rowsAfter = await everyRow();
      for (final table in rowsBefore.keys) {
        expect(rowsAfter[table], rowsBefore[table],
            reason: '$table comes back value for value');
      }
      expect(await ftsHits('lighthouse'), [(workId, 0)],
          reason: 'search finds the restored sentence again');
      final work = (await db.spineDao.workById(workId))!;
      expect(work.readLang, 'ru');
      expect(work.activeTranslationLang, 'ru');
      expect(work.showTranslationLayer, isTrue);
      expect(work.translationView, 'only');
      final a = await (db.select(db.alignments)
            ..where((a) => a.workId.equals(workId) & a.segmentIdx.equals(0)))
          .getSingle();
      expect(a.wordTimings, timings, reason: 'blobs survive the JSON');
      final pos = await (db.select(db.positions)
            ..where((p) => p.workId.equals(workId)))
          .getSingle();
      expect((pos.segmentIdx, pos.wordIdx), (1, 3));
      final capture = await (db.select(db.captures)
            ..where((c) => c.workId.equals(workId)))
          .getSingle();
      expect(capture.segmentIdx, 0, reason: 'rebound to its sentence');
      expect(await bin.list(), isEmpty, reason: 'restored, so it leaves');
    });

    test('delete translation then restore brings back only that language',
        () async {
      final message = await delete(StoredKind.translation, 'ru');
      expect(message,
          'Deleted the Russian translation. Restore it from Recently deleted.');
      expect(await db.spineDao.translationLangsOf(workId), ['de']);
      // Something else changes meanwhile; the restore must not undo it.
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 1,
          sentenceIdx: 0,
          lang: 'de',
          sourceText: 'He climbs the stairs.',
          body: 'de: stairs');

      final snap = (await bin.list()).single;
      expect(snap.lang, 'ru');
      expect(await restoreDeleted(db, bin, snap),
          'Restored the Russian translation of “Lighthouse”.');
      expect(await db.spineDao.translationLangsOf(workId), ['de', 'ru']);
      expect(await count('translation_sentences'), 3);
      expect(await count('segments'), 2);
      final work = (await db.spineDao.workById(workId))!;
      expect(work.readLang, 'ru');
      expect(work.activeTranslationLang, 'ru');
      expect(work.translationView, 'only');
    });

    test('restore refuses when a transcript exists', () async {
      await delete(StoredKind.transcript);
      await db.spineDao.insertSegments(
          workId, const [(idx: 0, kind: 'prose', text: 'A new take.')]);
      final snap = (await bin.list()).single;
      final rows = await bin.rowsOf(snap.id);
      expect(await db.spineDao.restoreTranscript(workId, rows),
          RestoreResult.transcriptExists);
      expect(await count('segments'), 1, reason: 'never two mixed');
      expect(await count('translation_sentences'), 0);
      expect(await restoreDeleted(db, bin, snap),
          'Not restored: this item has a newer transcript. Delete that one '
          'first to bring this one back.');
      expect(await bin.list(), hasLength(1), reason: 'still on offer');
    });

    test('restore refuses when that translation was made again', () async {
      await delete(StoredKind.translation, 'ru');
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: 1,
          sentenceIdx: 0,
          lang: 'ru',
          sourceText: 'He climbs the stairs.',
          body: 'new');
      final snap = (await bin.list()).single;
      expect(await restoreDeleted(db, bin, snap),
          'Not restored: this item has a newer Russian translation. Delete '
          'that one first to bring this one back.');
      expect(await count('translation_sentences'), 2, reason: 'de + new ru');
    });

    test('a translation whose transcript went too waits for the transcript',
        () async {
      await delete(StoredKind.translation, 'ru');
      await delete(StoredKind.transcript);
      final snaps = await bin.list();
      final ru = snaps.firstWhere((s) => s.kind == StoredKind.translation);
      expect(await restoreDeleted(db, bin, ru),
          'Not restored: the transcript it translates is gone. Restore the '
          'transcript first.');
      final transcript =
          snaps.firstWhere((s) => s.kind == StoredKind.transcript);
      await restoreDeleted(db, bin, transcript);
      expect(await restoreDeleted(db, bin, ru),
          'Restored the Russian translation of “Lighthouse”.');
      expect(await db.spineDao.translationLangsOf(workId), ['de', 'ru']);
    });

    test('restore refuses when the item is gone, and lets the copy go',
        () async {
      await delete(StoredKind.transcript);
      final snap = (await bin.list()).single;
      await db.customStatement('PRAGMA foreign_keys = OFF');
      await db.customStatement('DELETE FROM episodes');
      await db.customStatement('DELETE FROM captures');
      await db.customStatement('DELETE FROM works');
      expect(await db.spineDao.restoreTranscript(
              workId, await bin.rowsOf(snap.id)),
          RestoreResult.workGone);
      expect(await restoreDeleted(db, bin, snap),
          'Not restored: the item is no longer in your library.');
      expect(await bin.list(), isEmpty);
    });
  });

  group('restore never mixes', () {
    test('a translation is refused when its transcript changed', () async {
      await delete(StoredKind.translation, 'ru');
      await delete(StoredKind.transcript);
      // Transcribed again: same sentence numbers, different sentences.
      await db.spineDao.insertSegments(workId, const [
        (idx: 0, kind: 'prose', text: 'A storm at sea.'),
        (idx: 1, kind: 'prose', text: 'The boat turns back.'),
      ]);
      final ru = (await bin.list())
          .firstWhere((s) => s.kind == StoredKind.translation);
      expect(
          await db.spineDao
              .restoreTranslation(workId, 'ru', await bin.rowsOf(ru.id)),
          RestoreResult.sourceChanged);
      expect(await restoreDeleted(db, bin, ru),
          'Not restored: the transcript it translates has changed.');
      expect(await count('translation_sentences'), 0);
      expect(
          await db
              .customSelect("SELECT 1 FROM layers WHERE kind = 'mt'")
              .get(),
          isEmpty);
      expect(await bin.list(), hasLength(2), reason: 'both copies kept');
    });

    test('a transcript is refused while parts of another one are there',
        () async {
      await delete(StoredKind.transcript);
      // A layer row with the snapshot's own key, without any sentences.
      await db.spineDao.insertLayers(workId, const [
        (segmentIdx: 0, lang: 'fr', kind: 'transcript', text: 'Autre.'),
      ]);
      final snap = (await bin.list()).single;
      expect(
          await db.spineDao
              .restoreTranscript(workId, await bin.rowsOf(snap.id)),
          RestoreResult.transcriptExists);
      expect(await count('segments'), 0);
      expect(await count('layers'), 1);
    });

    test('a copy whose item was replaced by another is let go', () async {
      await delete(StoredKind.transcript);
      final snap = (await bin.list()).single;
      // A backup restore can hand the same id to a different item.
      await (db.update(db.works)..where((w) => w.id.equals(workId)))
          .write(const WorksCompanion(title: Value('Another show')));
      expect(
          await db.spineDao
              .restoreTranscript(workId, await bin.rowsOf(snap.id)),
          RestoreResult.workGone);
      expect(await restoreDeleted(db, bin, snap),
          'Not restored: the item is no longer in your library.');
      expect(await count('segments'), 0);
      expect(await bin.list(), isEmpty);
    });

    test('a same-titled episode with another guid is another item',
        () async {
      await delete(StoredKind.translation, 'ru');
      final snap = (await bin.list()).single;
      await (db.update(db.episodes)..where((e) => e.workId.equals(workId)))
          .write(const EpisodesCompanion(guid: Value('other')));
      expect(
          await db.spineDao
              .restoreTranslation(workId, 'ru', await bin.rowsOf(snap.id)),
          RestoreResult.workGone);
      expect(await db.spineDao.translationLangsOf(workId), ['de']);
    });

    test('open pages hear a restore', () async {
      await delete(StoredKind.transcript);
      final snap = (await bin.list()).single;
      final heard = <String>{};
      final subs = [
        db.spineDao.positionsMoved().listen((_) => heard.add('positions')),
        for (final name in const [
          'segments',
          'alignments',
          'layers',
          'translation_sentences',
          'works',
        ])
          db
              .tableUpdates(TableUpdateQuery.onTableName(name))
              .listen((_) => heard.add(name)),
      ];
      await pumpEventQueue();
      heard.clear();
      await restoreDeleted(db, bin, snap);
      await pumpEventQueue();
      for (final s in subs) {
        await s.cancel();
      }
      expect(
          heard,
          containsAll(const [
            'positions',
            'segments',
            'alignments',
            'layers',
            'translation_sentences',
            'works',
          ]));
    });

    test('a restore that fails says so and keeps the copy', () async {
      await delete(StoredKind.transcript);
      final snap = (await bin.list()).single;
      await db.customStatement(
          'CREATE TRIGGER no_segments BEFORE INSERT ON segments '
          "BEGIN SELECT RAISE(ABORT, 'disk I/O'); END");
      expect(await restoreDeleted(db, bin, snap),
          'Couldn’t restore it: something went wrong putting it back, so '
          'nothing changed. The copy is kept.');
      expect(await count('segments'), 0);
      expect(await count('translation_sentences'), 0);
      expect(await bin.list(), hasLength(1));
    });
  });

  group('a delete that fails', () {
    test('nothing is deleted when the copy can’t be saved', () async {
      // Where the folder should be, a file: the copy can't be written.
      File('${dir.path}/recently_deleted').writeAsStringSync('in the way');
      expect(await delete(StoredKind.transcript),
          'Kept: a copy couldn’t be saved, so nothing was deleted.');
      expect(await count('segments'), 2);
      expect(await count('translation_sentences'), 2);
    });

    test('no room for the copy is said plainly', () {
      expect(
          deleteFailedMessage(const FileSystemException('Write failed',
              '/x', OSError('No space left on device', 28))),
          'Kept: there was no room to keep a copy, so nothing was deleted.');
    });

    test('the copy is let go when the delete itself fails', () async {
      await db.customStatement(
          'CREATE TRIGGER keep_segments BEFORE DELETE ON segments '
          "BEGIN SELECT RAISE(ABORT, 'locked'); END");
      expect(await delete(StoredKind.transcript),
          'Kept: it couldn’t be deleted, so nothing changed.');
      expect(await count('segments'), 2);
      expect(await bin.list(), isEmpty, reason: 'no copy of what stayed');
      expect(Directory('${dir.path}/recently_deleted').listSync(), isEmpty);
    });
  });

  group('guards', () {
    test('translation delete kept while translating', () async {
      final gate = Completer<String>();
      final run = TranslationRun(
        dao: db.spineDao,
        workId: workId,
        units: const [
          TranslatableSentence(
              segIdx: 0, sentenceIdx: 0, text: 'The lighthouse keeper.'),
          TranslatableSentence(
              segIdx: 1, sentenceIdx: 0, text: 'He climbs the stairs.'),
        ],
        target: 'ru',
        steps: [
          TranslationStep(lang: 'ru', open: () async => _Held(gate.future)),
        ],
      );
      final running = run.start();
      await pumpEventQueue();

      expect(await delete(StoredKind.translation, 'ru'),
          'Kept: a translation is running for this item.');
      expect(await delete(StoredKind.transcript),
          'Kept: a translation is running for this item.',
          reason: 'the run would write sentences over a deleted transcript');
      expect(await db.spineDao.translationLangsOf(workId), ['de', 'ru']);
      expect(await bin.list(), isEmpty);

      // The reader is left: the run stops after the sentence in flight,
      // which still lands. Only once it has does the delete go ahead, so
      // nothing it writes can bring the language back.
      run.stop();
      gate.complete('ru: stairs');
      await running;
      expect(await delete(StoredKind.translation, 'ru'),
          startsWith('Deleted the Russian translation.'));
      await pumpEventQueue();
      expect(await db.spineDao.translationLangsOf(workId), ['de']);
    });

    test('the English of a transcribe-and-translate job is kept', () async {
      await db.jobsDao.save(Job(
        id: translateJobId(workId),
        kind: 'transcribe',
        state: JobState.running,
        checkpoint: null,
        totalUnits: 0,
        doneUnits: 0,
        createdAtMs: 1,
      ));
      await db.jobsDao.setPayload(translateJobId(workId),
          jsonEncode({'workId': workId, 'translate': true}));
      expect(await delete(StoredKind.translation, 'en'),
          'Kept: a translation is running for this item.');
      expect(await delete(StoredKind.translation, 'de'),
          startsWith('Deleted the German translation.'),
          reason: 'Whisper only ever writes English');
    });
  });

  group('the store', () {
    DeletedSnapshot meta(String id, DateTime at) => DeletedSnapshot(
        id: id,
        workId: workId,
        workTitle: 'Lighthouse',
        kind: StoredKind.translation,
        lang: 'ru',
        deletedAt: at,
        bytes: 10);

    test('purge drops snapshots older than 30 days', () async {
      final now = DateTime(2026, 11, 6, 12);
      final store = RecentlyDeleted(Directory('${dir.path}/rd'), now: () => now);
      await store.save(meta('old', now.subtract(const Duration(days: 31))),
          const {'translation_sentences': []});
      await store.save(meta('fresh', now.subtract(const Duration(days: 2))),
          const {'translation_sentences': []});
      // A damaged file never blocks the purge or the list.
      File('${dir.path}/rd/broken.json').writeAsStringSync('{not json');

      expect(await store.purgeOlderThan(const Duration(days: 30)), 1);
      expect([for (final s in await store.list()) s.id], ['fresh']);
      expect(() => store.rowsOf('old'), throwsA(anything));
    });

    test('a missing folder purges nothing', () async {
      final store = RecentlyDeleted(Directory('${dir.path}/none'));
      expect(await store.purgeOlderThan(const Duration(days: 30)), 0);
      expect(await store.list(), isEmpty);
    });

    test('the web tier has no bin, and its deletes still ask first', () {
      expect(testServices(dir, localMlAvailable: false).recentlyDeleted,
          isNull);
    });
  });

  group('Models & storage', () {
    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
          home: ModelsScreen(
              store: FakeModelStore(),
              registry: ModelRegistry.starter(),
              services: services,
              db: db,
              profileId: profile)));
      await tester.pumpAndSettle();
    }

    testWidgets('Recently deleted is hidden when empty', (tester) async {
      await pump(tester);
      expect(find.byKey(const Key('recently-deleted')), findsNothing);
      expect(find.text('Recently deleted'), findsNothing);
    });

    testWidgets(
        'one row per snapshot, with Restore and a ⋮ Delete now', (tester) async {
      await tester.runAsync(() async {
        await delete(StoredKind.translation, 'ru');
        await delete(StoredKind.transcript);
      });
      await pump(tester);
      expect(find.text('Recently deleted'), findsOneWidget);
      final snaps = await tester.runAsync(bin.list);
      expect(snaps, hasLength(2));
      for (final s in snaps!) {
        expect(find.byKey(Key('deleted-${s.id}')), findsOneWidget);
      }
      final ru = snaps.firstWhere((s) => s.kind == StoredKind.translation);
      final tr = snaps.firstWhere((s) => s.kind == StoredKind.transcript);
      expect(
          find.descendant(
              of: find.byKey(Key('deleted-${ru.id}')),
              matching: find.text('Lighthouse')),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(Key('deleted-${ru.id}')),
              matching: find.textContaining('Russian translation · ')),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(Key('deleted-${tr.id}')),
              matching: find.textContaining('Transcript · ')),
          findsOneWidget);

      // Restore the transcript: it leaves the list and comes back.
      await tester.tap(find.byKey(Key('deleted-restore-${tr.id}')));
      await tester.pumpAndSettle();
      expect(find.text('Restored the transcript of “Lighthouse”.'),
          findsOneWidget);
      expect(find.byKey(Key('deleted-${tr.id}')), findsNothing);
      expect(await tester.runAsync(() => count('segments')), 2);

      // Delete now asks, since nothing brings it back after.
      await tester.tap(find.byKey(Key('deleted-menu-${ru.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete now'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog), matching: find.text('Delete now')));
      await tester.pumpAndSettle();
      expect(find.text('Recently deleted'), findsNothing);
      expect(await tester.runAsync(bin.list), isEmpty);
    });

    testWidgets('a second tap on Restore while it runs does nothing',
        (tester) async {
      await tester.runAsync(() => delete(StoredKind.transcript));
      // The copy is read only when the test lets it: Restore is held
      // mid-run, as a slow phone would hold it.
      final gate = Completer<void>();
      final held = _HeldBin(bin.dir, gate.future);
      services = _ServicesWithBin(services, held);
      await pump(tester);
      final s = (await tester.runAsync(bin.list))!.single;
      final restore = find.byKey(Key('deleted-restore-${s.id}'));
      await tester.tap(restore);
      await tester.pump();
      expect(tester.widget<TextButton>(restore).onPressed, isNull,
          reason: 'Restore waits while it runs');
      expect(tester.widget<PopupMenuButton<String>>(
              find.byKey(Key('deleted-menu-${s.id}'))).enabled,
          isFalse,
          reason: 'and so does Delete now');
      await tester.tap(restore, warnIfMissed: false);
      await tester.pump();
      gate.complete();
      await tester.pumpAndSettle();
      expect(held.reads, 1, reason: 'one restore ran');
      expect(find.text('Restored the transcript of “Lighthouse”.'),
          findsOneWidget);
      expect(find.textContaining('Not restored'), findsNothing);
      expect(find.textContaining('Couldn’t restore'), findsNothing);
    });

    testWidgets('survives 320 dp at twice the text size', (tester) async {
      await tester.runAsync(() => delete(StoredKind.translation, 'ru'));
      tester.view.physicalSize = const Size(320, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
              data: const MediaQueryData(
                  size: Size(320, 3000), textScaler: TextScaler.linear(2)),
              child: ModelsScreen(
                  store: FakeModelStore(),
                  registry: ModelRegistry.starter(),
                  services: services,
                  db: db,
                  profileId: profile))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Recently deleted'), findsOneWidget);
    });

    testWidgets('Storage by item deletes a transcript without asking',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
          home: StorageByItemScreen(
              db: db, services: services, profileId: profile)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('stored-delete-transcript-$workId')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(
          find.text('Deleted the transcript. Restore it from Recently '
              'deleted.'),
          findsOneWidget);
      expect(await tester.runAsync(bin.list), hasLength(1));
    });
  });
}

/// A translator whose first sentence answers when the test says so.
class _Held implements SentenceTranslator {
  final Future<String> first;
  var _calls = 0;
  _Held(this.first);

  @override
  Future<String> translate(String sentence) =>
      _calls++ == 0 ? first : Future.value('ru: $sentence');

  @override
  Future<void> dispose() async {}
}

/// A bin whose copies are read only once [gate] opens.
class _HeldBin extends RecentlyDeleted {
  final Future<void> gate;
  var reads = 0;
  _HeldBin(super.dir, this.gate);

  @override
  Future<SnapshotRows> rowsOf(String id) async {
    reads++;
    await gate;
    return super.rowsOf(id);
  }
}

/// [inner]'s services, with [bin] as Recently deleted.
class _ServicesWithBin extends DeviceServices {
  final RecentlyDeleted bin;
  _ServicesWithBin(DeviceServices inner, this.bin)
      : super(
          supportDir: inner.supportDir,
          modelStore: inner.modelStore,
          registry: inner.registry,
          decoder: inner.decoder,
          audioFetcher: inner.audioFetcher,
          executor: inner.executor,
          foregroundGate: inner.foregroundGate,
          engineFor: inner.engineFor,
        );

  @override
  RecentlyDeleted? get recentlyDeleted => bin;
}
