import 'dart:convert';

import 'package:backup_core/backup_core.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_core/study_core.dart' as study;
import 'package:trellis/db/database.dart';
import 'package:trellis/features/backup/db_bridge.dart';

/// The Drift <-> backup_core seam. Contracts pinned here:
///
///  - export emits EXACTLY the canonical table set (consents cannot travel
///    because no consents table exists to read — ADR-0003 law 6);
///  - river metadata rides ON the work row and the word ledger ON the
///    profile row, so the canonical 11-table payload still round-trips the
///    whole device;
///  - restore is FULL-REPLACE (the payload carries raw integer ids, which
///    merging could never keep collision-free);
///  - donor imports MERGE into one profile, SM-2 state 1:1, and everything
///    that finds no home here is counted, never silently dropped.
const phrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon about';

/// A donor Trellis `.ohbk` blob, pre-built with the donor's own derivation
/// (appDomain `trellis`, AAD `trellis-backup/v1`) under [phrase]. Payload:
///  - importedIds: [course-a, course-bad]
///  - courses: course-a = [donorCourseABody] (parses), course-bad = a
///    two-key JSON our strict parser refuses
///  - cards: course-a/item-1 (2.1/6/20670/2/1), bundled-1/item-b
///    (2.8/12/20680/4/0) with NO body (donor bundled-course progress),
///    ghost/item-g for a course nowhere on this device.
final Uint8List donorTrellisBlob = base64Decode(
    'T0hCSwIB0ViqkmJ+CK/h67VdHtidgQkvWfyZndeQdL27VBliJnrai2qD8AKdON+Bknm/u+ish7ci'
    'vo1uiL/gbkBLv76AwYJAPvXpmUQjoHz/umcSbsv1gurToVdgsl5D9yA0JMLnluMR9JZWYsCgr6bw'
    'GgJQWcfKTekj6oSUVGc2osld9/jcawtz3jTVgWFs+SJYnv1al4vBRLQlzY8zYUq6Qvo+yV5NJBpb'
    'YapCAHHI0cmQXGa0FqVABsyfLzXmlkWp/cu2vkxSBA28ioSrfkcnyhZ51aTWRVD/Zgl2wYw0z7I7'
    'RA4VoDe4/PgCPTFjAVGC34BTK3kEKSeshXKskrIXgeOFzgIzI7DNkH3X9GS2SNVu/57/iexygmV8'
    '9j0hivvsqtEqpF51L12uBOUYhlstMd7KbcE5SkykgV1l6Acw8NCkwm5LSG3h979WJtraZNKsPADZ'
    'LOCe/QtPRGzW3aDhcnn5qWEYG4E4vplVybz+n7fCHjN7Y5/+7/zpUUIhNP2/LV3AaCN2+7gli+Vr'
    'ZZc/Qx+f/0GB4/YjQvQODXTPxCiN2oj3J9Zw9aAK3YUA2wOGLLRa65VFrjX3fOreccLlPtntruvn'
    '7JdgxsPSCKo0eMMxRKMqdAgmJXhTJb5mTPdgocIakyfOcUsHyhppR+dZxhSyp4LCQh93aIkEce9g'
    '+7zuhft2tKzS9Ru8SE0E/jg4BCXjMVsLjSKBvwxXzYB5Xq3jpKWcj7BnpM5yP3RcG512W730fG4l'
    'vsgL+kNRZkQAYCByDg2A0ji8yt/3OWvW1ACPLIzXKCQNYN26yQOSsFWt8uML7zwvtkw/IKrSM15m'
    'WwTa6iXembt+YcHhFm6u5E/40VjV+6VzMZiojAsuSyl5cwdvq4h+7N4GHAMy8nGWZLYNHs4bVpTb'
    'i/LFmdGWDC7p/o7QS4ROCxGjbccoErtERnVkxShjBzYzJHahzZlIqeCtadS4mhtvUlnDELElME2Q'
    'C+3Uu3OC2thveZeksi1/YgDLgwFUr58k0K1J6tFIfK/8hLgh8wFc/YnTMezXzmrTpPKr+7lqJPtW'
    'pgPq3MnAVzpl+Yhz90Yys9rkN61RXG96p2BOn4w6rGp3XzNbhxk6gxBrJbA3JbmdeKw=');

const donorCourseABody =
    '{"schemaVersion":"1.0","id":"course-a","title":"Alpha","nodes":'
    '[{"id":"n1","title":"Node One","intake":"Read this.","items":'
    '[{"id":"item-1","type":"cloze","rung":1,"text":"The sky is '
    '{{c1::blue}}.","answers":{"c1":"blue"}}]}]}';

String ourCourseJson({String id = 'c1', String title = 'Course One'}) =>
    json.encode({
      'schemaVersion': '1.0',
      'id': id,
      'title': title,
      'nodes': [
        {
          'id': 'n1',
          'title': 'Node One',
          'intake': 'Read this.',
          'items': [
            {
              'id': 'i1',
              'type': 'cloze',
              'rung': 1,
              'text': 'The sky is {{c1::blue}}.',
              'answers': {'c1': 'blue'},
            },
          ],
        },
      ],
    });

/// One of everything the schema can hold, so the round-trip test fails the
/// moment a table (or a nested rider) stops travelling.
Future<void> seedRichly(AppDatabase db) async {
  final ada = await db.profilesDao.create('Ada');
  await db.profilesDao.create('Ben');

  final walden = await db.spineDao.insertWork(
      profileId: ada,
      kind: 'book',
      title: 'Walden',
      persistence: 'work',
      firstSeenEpochDay: 20600,
      lang: 'en');
  await db.spineDao.insertSegments(walden, [
    (idx: 0, kind: 'heading', text: 'Economy'),
    (idx: 1, kind: 'prose', text: 'I went to the woods'),
  ]);
  await db.spineDao.insertLayers(walden, [
    (segmentIdx: 1, lang: 'pt', kind: 'translation', text: 'Fui'),
  ]);
  await db.into(db.alignments).insert(AlignmentsCompanion.insert(
      workId: walden,
      segmentIdx: 1,
      tStartMs: 0,
      tEndMs: 1000,
      wordTimings: const Value(null)));
  await db.into(db.alignments).insert(AlignmentsCompanion.insert(
      workId: walden,
      segmentIdx: 0,
      tStartMs: 1000,
      tEndMs: 2000,
      wordTimings: Value(Uint8List.fromList([1, 2, 3]))));
  await db.spineDao.savePosition(
      profileId: ada,
      workId: walden,
      segmentIdx: 1,
      wordIdx: 4,
      lastModality: 'read');

  final feed = await db.feedsDao.insertFeed(
      profileId: ada, url: 'https://a.example/feed.xml', title: 'A');
  final episodeWork = await db.spineDao.insertWork(
      profileId: ada,
      kind: 'episode',
      title: 'Episode One',
      persistence: 'ephemeron',
      firstSeenEpochDay: 20650,
      sourceUrl: 'https://a.example/1.mp3');
  await db.feedsDao.insertEpisode(
      workId: episodeWork,
      feedId: feed,
      guid: 'guid-1',
      enclosureUrl: 'https://a.example/1.mp3',
      durationMs: 60000,
      publishedAtMs: 1754000000000);
  await db.feedsDao
      .savePlayerPosition(profileId: ada, workId: episodeWork, tMs: 4200);

  final courseRow = await db.studyDao
      .importCourse(profileId: ada, raw: ourCourseJson(), nowMs: 111);
  const before = study.CardState(
      itemId: 'i1',
      ease: 2.5,
      intervalDays: 0,
      dueEpochDay: 20670,
      reps: 0,
      lapses: 0);
  await db.studyDao.recordGrade(
      courseRowId: courseRow,
      before: before,
      after: before.copyWith(reps: 1, intervalDays: 1, dueEpochDay: 20671),
      grade: study.Grade.good,
      tsMs: 999);

  await db.ledgerDao.add(
      profileId: ada,
      word: 'woods',
      lang: 'en',
      sourceWorkId: walden,
      nowMs: 555);
}

void main() {
  late AppDatabase db;
  late DbBridge bridge;
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    bridge = DbBridge(db);
  });
  tearDown(() => db.close());

  group('exportTables', () {
    test('emits exactly the canonical table set', () async {
      await seedRichly(db);
      final tables = await bridge.exportTables();
      expect(tables.keys.toSet(), espalierBackupTables.toSet(),
          reason: 'RowPayload.encode refuses anything else — and consents '
              'cannot travel because no consents table exists to read');
    });

    test('river metadata rides on the work row, the ledger on the profile row',
        () async {
      await seedRichly(db);
      final tables = await bridge.exportTables();

      final episodeWork = tables['works']!
          .singleWhere((w) => w['kind'] == 'episode');
      final episode = episodeWork['episode'] as Map<String, Object?>;
      expect(episode['guid'], 'guid-1');
      expect(episode['durationMs'], 60000);

      final book = tables['works']!.singleWhere((w) => w['kind'] == 'book');
      expect(book.containsKey('episode'), isFalse,
          reason: 'a work without river metadata carries no rider');

      final ada =
          tables['profiles']!.singleWhere((p) => p['name'] == 'Ada');
      final ledger = ada['wordLedger'] as List;
      expect((ledger.single as Map)['word'], 'woods');
    });

    test('a blob column survives as a JSON-safe list', () async {
      await seedRichly(db);
      final tables = await bridge.exportTables();
      final timed = tables['alignments']!
          .singleWhere((a) => a['wordTimings'] != null);
      // jsonEncode must accept the whole payload — that IS the wire format.
      expect(jsonDecode(jsonEncode(timed['wordTimings'])), [1, 2, 3]);
    });
  });

  group('encrypt -> decrypt -> full-replace restore', () {
    test('reproduces every row on a second device, ids intact', () async {
      await seedRichly(db);
      final payload = RowPayload.encode(await bridge.exportTables(),
          createdAt: DateTime.utc(2026, 8, 11));
      final blob = await EspalierBackup.encrypt(payload, phrase: phrase);

      final db2 = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db2.close);
      final bridge2 = DbBridge(db2);
      // Pre-existing data on the target device must not survive: the
      // payload's raw integer ids make merging collision-prone by
      // construction, so restore is full-replace.
      final zed = await db2.profilesDao.create('Zed');
      await db2.spineDao.insertWork(
          profileId: zed,
          kind: 'note',
          title: 'Doomed',
          persistence: 'work',
          firstSeenEpochDay: 1);

      final plain = await EspalierBackup.decrypt(blob, phrase: phrase);
      await bridge2.restoreFullReplace(RowPayload.decode(plain));

      final names = (await db2.profilesDao.all()).map((p) => p.name);
      expect(names, ['Ada', 'Ben']);
      expect(await bridge2.exportTables(), await bridge.exportTables(),
          reason: 'the canonical row maps are the equality of two devices');

      // Typed spot checks: ids and FK edges landed verbatim.
      final ada = (await db2.profilesDao.all()).first;
      final works = await db2.spineDao.worksOf(ada.id);
      expect(works.map((w) => w.title).toSet(), {'Walden', 'Episode One'});
      final episodeWork =
          works.singleWhere((w) => w.kind == 'episode');
      expect((await db2.feedsDao.episodeOf(episodeWork.id))?.guid, 'guid-1');
      final courseRow =
          (await db2.studyDao.coursesOf(ada.id)).single;
      final cards = await db2.studyDao.loadCardStates(courseRow.id);
      expect(cards['i1']!.dueEpochDay, 20671);
      expect((await db2.studyDao.revlogOf(courseRow.id)).single.tsMs, 999);
      expect(
          (await db2.ledgerDao.wordsOf(ada.id)).single.word, 'woods');
    });
  });

  group('applyTrellis', () {
    Future<TrellisImportResult> import() => TrellisImporter.importBackup(
        donorTrellisBlob,
        phrase: phrase,
        profileId: '1');

    test('courses land verbatim through the strict parser, SM-2 state 1:1',
        () async {
      final ada = await db.profilesDao.create('Ada');
      // The "bundled course" case: this device already has bundled-1, the
      // donor backup carries only its progress.
      final bundledRow = await db.studyDao.importCourse(
          profileId: ada,
          raw: ourCourseJson(id: 'bundled-1', title: 'Bundled'),
          nowMs: 5);

      final report =
          await bridge.applyTrellis(await import(), profileId: ada, nowMs: 7);

      final courses = await db.studyDao.coursesOf(ada);
      expect(courses.map((c) => c.courseId).toSet(), {'bundled-1', 'course-a'});
      expect(
          courses.singleWhere((c) => c.courseId == 'course-a').raw,
          donorCourseABody,
          reason: 'donor bodies are stored verbatim, never re-serialized');

      final courseARow =
          courses.singleWhere((c) => c.courseId == 'course-a');
      final aCards = await db.studyDao.loadCardStates(courseARow.id);
      final item1 = aCards['item-1']!;
      expect(item1.ease, 2.1);
      expect(item1.intervalDays, 6);
      expect(item1.dueEpochDay, 20670);
      expect(item1.reps, 2);
      expect(item1.lapses, 1);

      final bundledCards = await db.studyDao.loadCardStates(bundledRow);
      expect(bundledCards['item-b']!.reps, 4,
          reason: 'bundled-course progress is the user\'s — it lands on the '
              'course this device already has');

      expect(report.imported, {'courses': 1, 'cards': 2});
      expect(report.skipped.values.fold<int>(0, (a, b) => a + b), 2,
          reason: 'the unparseable course and the ghost-course card are '
              'counted, never silently dropped');
      expect(report.dropped, isNotEmpty,
          reason: 'the engine\'s empty-revlog sentence travels through');
    });

    test('re-applying the same backup duplicates nothing', () async {
      final ada = await db.profilesDao.create('Ada');
      await bridge.applyTrellis(await import(), profileId: ada, nowMs: 7);
      await bridge.applyTrellis(await import(), profileId: ada, nowMs: 8);

      final courses = await db.studyDao.coursesOf(ada);
      expect(courses.length, 1);
      final cards = await db.studyDao.loadCardStates(courses.single.id);
      expect(cards.length, 1);
    });
  });

  group('applyPrimer', () {
    Map<String, Object?> primerExport() => {
          'version': 1,
          'exportedAt': '2026-08-01T00:00:00.000Z',
          'profile': {
            'name': 'Reader',
            'pid': 'gentle-oak-1234',
            'prefs': {'parentPin': '4321'},
            'stats': {'wordsRead': 100, 'minutes': 5, 'sessions': 2},
            'feeds': [
              {'url': 'https://a.example/feed.xml', 'title': 'A'},
            ],
          },
          'books': [
            {
              'id': 'gentle-oak-1234::walden.epub::4242',
              'kind': 'book',
              'title': 'Walden',
              'filename': 'walden.epub',
              'size': 4242,
              'source': {'kind': 'file', 'label': 'walden.epub'},
              'position': 1234,
              'addedAt': 1753000000000,
              'lastReadAt': 1754000000000,
              'sourceLang': 'en',
              'parsed': {
                'blocks': [
                  {'type': 'chapter', 'title': 'Economy'},
                  {'type': 'text', 'text': 'I went to the woods'},
                  {'type': 'segment', 'kind': 'code', 'content': 'x = 1'},
                  {
                    'type': 'segment',
                    'kind': 'figure',
                    'content': {'src': 'fig.png', 'alt': 'a pond'},
                  },
                ],
              },
            },
          ],
          'extracts': [
            {
              'id': 'ext::1',
              'bookId': 'gentle-oak-1234::walden.epub::4242',
              'createdAt': 1753500000000,
              'EF': 2.3,
              'reps': 2,
              'interval': 6,
              'nextReview': 1786061234567,
              'history': [
                {'t': 1785000000000, 'g': 5},
                {'t': 1785100000000, 'g': 2},
              ],
              'kind': 'word',
              'focusWord': 'woods',
              'context': 'I went to the woods',
            },
            {
              'id': 'ext::2',
              'createdAt': 1753600000000,
              'EF': 2.5,
              'reps': 0,
              'interval': 0,
              'kind': 'passage',
              'context': 'A passage worth keeping',
            },
          ],
        };

    PrimerImportResult import() =>
        OhPrimerImporter.importJson(jsonEncode(primerExport()), profileId: '1');

    test('works, reading positions, feeds and vocabulary find their homes',
        () async {
      final ada = await db.profilesDao.create('Ada');
      final report =
          await bridge.applyPrimer(import(), profileId: ada, nowMs: 999);

      final work = (await db.spineDao.worksOf(ada)).single;
      expect(work.title, 'Walden');
      expect(work.kind, 'book');
      expect(work.lang, 'en');
      expect(work.persistence, 'work');
      expect(work.firstSeenEpochDay, 1753000000000 ~/ 86400000);

      final segments = await db.spineDao.segmentsOf(work.id);
      expect(segments.map((s) => (s.kind, s.body)).toList(), [
        ('heading', 'Economy'),
        ('prose', 'I went to the woods'),
        ('code', 'x = 1'),
        ('figure', 'a pond'),
      ]);

      final position =
          await db.spineDao.position(profileId: ada, workId: work.id);
      expect((position!.segmentIdx, position.wordIdx), (0, 1234));
      expect(position.updatedAtMs, 1754000000000,
          reason: 'the donor knew when the book was last read — keep it');

      expect((await db.feedsDao.feedsOf(ada)).single.url,
          'https://a.example/feed.xml');

      final ledger = (await db.ledgerDao.wordsOf(ada)).single;
      expect(ledger.word, 'woods');
      expect(ledger.sourceWorkId, work.id);
      expect(ledger.addedAtMs, 1753500000000);

      expect(report.imported['works'], 1);
      expect(report.imported['segments'], 4);
      expect(report.imported['wordLedger'], 1);
      expect(report.imported.containsKey('cards'), isFalse,
          reason: 'nothing lands in the SRS deck — there is no course to '
              'hold an extract');
      expect(report.skipped.values.fold<int>(0, (a, b) => a + b),
          greaterThanOrEqualTo(2),
          reason: 'the passage extract and its review history are counted');
      expect(report.dropped.length, greaterThan(3),
          reason: 'the engine\'s dropped sentences travel through, plus the '
              'bridge\'s own (stats, extract schedules)');
    });

    test('re-applying the same export duplicates nothing', () async {
      final ada = await db.profilesDao.create('Ada');
      await bridge.applyPrimer(import(), profileId: ada, nowMs: 999);
      await bridge.applyPrimer(import(), profileId: ada, nowMs: 999);

      expect((await db.spineDao.worksOf(ada)).length, 1);
      expect((await db.ledgerDao.wordsOf(ada)).length, 1);
      expect((await db.feedsDao.feedsOf(ada)).length, 1);
    });
  });
}
