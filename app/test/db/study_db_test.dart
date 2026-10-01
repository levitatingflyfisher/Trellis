import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:study_core/study_core.dart';
import 'package:trellis/db/database.dart';

import '../support/schema_strip.dart';

/// A fresh, never-reviewed FSRS card for item [id], due [today].
FsrsCardState newFsrsCard(String id, int today) =>
    FsrsCardState.initial(id, today);

/// The study slice's storage contract (proposal-2 §6): a course row is the
/// verbatim `.ohcourse` text (study_core's strict parser is the single
/// authority — a file that doesn't parse leaves ZERO rows behind), a card row
/// is one item's SRS state, and the revlog is an append-only fold source —
/// the DAO exposes append and read, nothing that mutates or deletes.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<int> seedProfile() => db.profilesDao.create('Ada');

  String courseJson({String id = 'c1', String title = 'Course One'}) =>
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

  group('course import', () {
    test('a valid .ohcourse lands verbatim with title and timestamp', () async {
      final profileId = await seedProfile();
      final rawText = courseJson();
      final id = await db.studyDao.importCourse(
        profileId: profileId,
        raw: rawText,
        nowMs: 1234,
      );

      final rows = await db.studyDao.coursesOf(profileId);
      final row = rows.single;
      expect(row.id, id);
      expect(row.courseId, 'c1');
      expect(row.title, 'Course One');
      expect(row.raw, rawText, reason: 'the stored text is the file, verbatim');
      expect(row.importedAtMs, 1234);
    });

    test('invalid JSON throws the parser error and imports NOTHING', () async {
      final profileId = await seedProfile();
      await expectLater(
        db.studyDao.importCourse(
          profileId: profileId,
          raw: 'not json at all',
          nowMs: 0,
        ),
        throwsFormatException,
      );
      expect(
        await db.studyDao.coursesOf(profileId),
        isEmpty,
        reason: 'the parser law: never a half-import',
      );
    });

    test(
      'a structurally bad course (unknown item type) imports NOTHING',
      () async {
        final profileId = await seedProfile();
        final bad = json.encode({
          'schemaVersion': '1.0',
          'id': 'c-bad',
          'title': 'Bad',
          'nodes': [
            {
              'id': 'n1',
              'title': 'N',
              'intake': 'x',
              'items': [
                {'id': 'i1', 'type': 'essay', 'rung': 1},
              ],
            },
          ],
        });
        await expectLater(
          db.studyDao.importCourse(profileId: profileId, raw: bad, nowMs: 0),
          throwsFormatException,
        );
        expect(await db.studyDao.coursesOf(profileId), isEmpty);
      },
    );

    test(
      're-importing the same course id replaces the body, keeps the cards',
      () async {
        final profileId = await seedProfile();
        final id = await db.studyDao.importCourse(
          profileId: profileId,
          raw: courseJson(),
          nowMs: 1,
        );
        await db.studyDao.recordGrade(
          courseRowId: id,
          before: CardState.initial('i1', const SrsDefaults(), 100),
          after: const CardState(
            itemId: 'i1',
            ease: 2.5,
            intervalDays: 1,
            dueEpochDay: 101,
            reps: 1,
            lapses: 0,
          ),
          grade: Grade.good,
          tsMs: 5,
        );

        final again = await db.studyDao.importCourse(
          profileId: profileId,
          raw: courseJson(title: 'Course One, revised'),
          nowMs: 2,
        );
        expect(again, id, reason: 'same course id, same row');

        final rows = await db.studyDao.coursesOf(profileId);
        expect(rows.single.title, 'Course One, revised');
        final cards = await db.studyDao.loadClassicHalves(id);
        expect(
          cards['i1']!.intervalDays,
          1,
          reason: 'a re-import never wipes learning history',
        );
      },
    );

    test('two profiles import the same course independently', () async {
      final a = await seedProfile();
      final b = await db.profilesDao.create('Beatrix');
      final rowA = await db.studyDao.importCourse(
        profileId: a,
        raw: courseJson(),
        nowMs: 1,
      );
      final rowB = await db.studyDao.importCourse(
        profileId: b,
        raw: courseJson(),
        nowMs: 2,
      );
      expect(rowA, isNot(rowB));
      expect(await db.studyDao.coursesOf(a), hasLength(1));
      expect(await db.studyDao.coursesOf(b), hasLength(1));
    });
  });

  group('cards and revlog', () {
    test('card state round-trips through its JSON column', () async {
      final profileId = await seedProfile();
      final id = await db.studyDao.importCourse(
        profileId: profileId,
        raw: courseJson(),
        nowMs: 1,
      );

      expect(await db.studyDao.loadClassicHalves(id), isEmpty);

      const after = CardState(
        itemId: 'i1',
        ease: 2.36,
        intervalDays: 6,
        dueEpochDay: 106,
        reps: 2,
        lapses: 1,
      );
      await db.studyDao.recordGrade(
        courseRowId: id,
        before: CardState.initial('i1', const SrsDefaults(), 100),
        after: after,
        grade: Grade.hard,
        tsMs: 9,
      );

      final loaded = (await db.studyDao.loadClassicHalves(id))['i1']!;
      expect(loaded.ease, after.ease);
      expect(loaded.intervalDays, after.intervalDays);
      expect(loaded.dueEpochDay, after.dueEpochDay);
      expect(loaded.reps, after.reps);
      expect(loaded.lapses, after.lapses);
    });

    test(
      'every grade APPENDS one revlog row; the card row is upserted',
      () async {
        final profileId = await seedProfile();
        final id = await db.studyDao.importCourse(
          profileId: profileId,
          raw: courseJson(),
          nowMs: 1,
        );

        var state = CardState.initial('i1', const SrsDefaults(), 100);
        var next = scheduleSm2(state, Grade.good, 100);
        await db.studyDao.recordGrade(
          courseRowId: id,
          before: state,
          after: next,
          grade: Grade.good,
          tsMs: 10,
        );
        state = next;
        next = scheduleSm2(state, Grade.again, 100);
        await db.studyDao.recordGrade(
          courseRowId: id,
          before: state,
          after: next,
          grade: Grade.again,
          tsMs: 20,
        );

        final log = await db.studyDao.revlogOf(id);
        expect(log, hasLength(2), reason: 'one row per grade, none replaced');
        expect(log[0].grade, 'good');
        expect(log[0].tsMs, 10);
        expect(log[0].intervalBeforeDays, 0);
        expect(log[0].intervalAfterDays, 1);
        expect(log[1].grade, 'again');
        expect(log[1].intervalBeforeDays, 1);
        expect(
          log[1].intervalAfterDays,
          0,
          reason: 'a lapse resets the interval',
        );

        final cards = await db.studyDao.loadClassicHalves(id);
        expect(cards, hasLength(1), reason: 'one card row per item, upserted');
        expect(cards['i1']!.lapses, 1);
      },
    );

    test(
        'totalReviewsOf sums revlog rows across every course a profile '
        'has, scoped to that profile only (Campaign 4 Phase 5\'s Echo tile)',
        () async {
      final ada = await seedProfile();
      final grace = await seedProfile();

      final course1 = await db.studyDao
          .importCourse(profileId: ada, raw: courseJson(), nowMs: 1);
      final course2 = await db.studyDao.importCourse(
          profileId: ada, raw: courseJson(id: 'second'), nowMs: 2);
      final graceCourse = await db.studyDao
          .importCourse(profileId: grace, raw: courseJson(), nowMs: 3);

      Future<void> grade(int courseRowId, int tsMs) async {
        final state = CardState.initial('i1', const SrsDefaults(), 100);
        final next = scheduleSm2(state, Grade.good, 100);
        await db.studyDao.recordGrade(
            courseRowId: courseRowId,
            before: state,
            after: next,
            grade: Grade.good,
            tsMs: tsMs);
      }

      await grade(course1, 10);
      await grade(course1, 11);
      await grade(course2, 12);
      await grade(graceCourse, 20);

      expect(await db.studyDao.totalReviewsOf(ada), 3);
      expect(await db.studyDao.totalReviewsOf(grace), 1);
    });

    test(
      'the fold: replaying the revlog through scheduleSm2 lands on the card row',
      () async {
        final profileId = await seedProfile();
        final id = await db.studyDao.importCourse(
          profileId: profileId,
          raw: courseJson(),
          nowMs: 1,
        );

        var state = CardState.initial('i1', const SrsDefaults(), 100);
        for (final (g, ts) in [
          (Grade.good, 1),
          (Grade.good, 2),
          (Grade.hard, 3),
        ]) {
          final next = scheduleSm2(state, g, 100);
          await db.studyDao.recordGrade(
            courseRowId: id,
            before: state,
            after: next,
            grade: g,
            tsMs: ts,
          );
          state = next;
        }

        // The stored card state is exactly the fold of the log — the revlog is
        // a source of truth the card row merely caches.
        var folded = CardState.initial('i1', const SrsDefaults(), 100);
        for (final entry in await db.studyDao.revlogOf(id)) {
          folded = scheduleSm2(folded, Grade.values.byName(entry.grade), 100);
        }
        final stored = (await db.studyDao.loadClassicHalves(id))['i1']!;
        expect(folded.intervalDays, stored.intervalDays);
        expect(folded.ease, stored.ease);
        expect(folded.reps, stored.reps);
        expect(folded.lapses, stored.lapses);
      },
    );

    test('loadCards skips a malformed row individually, the rest of '
        'the course survives (the store\'s own skip-the-entry law, not yet '
        'held by the live Drift path before this fix)', () async {
      final profileId = await seedProfile();
      final id = await db.studyDao.importCourse(
        profileId: profileId,
        raw: courseJson(),
        nowMs: 1,
      );

      const good = CardState(
        itemId: 'i1',
        ease: 2.5,
        intervalDays: 6,
        dueEpochDay: 106,
        reps: 2,
        lapses: 0,
      );
      await db.studyDao.recordGrade(
        courseRowId: id,
        before: CardState.initial('i1', const SrsDefaults(), 100),
        after: good,
        grade: Grade.good,
        tsMs: 1,
      );
      // Hand-corrupt a second card row's blob directly — the shape a real
      // decode failure (bad JSON, wrong types) would leave behind.
      await db
          .into(db.cards)
          .insert(
            CardsCompanion.insert(
              courseId: id,
              itemId: 'i2',
              stateJson: '{not valid json',
            ),
          );

      final cards = await db.studyDao.loadCards(id);
      expect(
        cards.keys,
        ['i1'],
        reason:
            'the malformed i2 entry is skipped, not thrown for the '
            'whole course',
      );
      expect(cards['i1']!.progress.intervalDays, 6);
    });

    group('both scheduler halves in one blob', () {
      Future<int> importOne() async {
        final profileId = await seedProfile();
        return db.studyDao.importCourse(
          profileId: profileId,
          raw: courseJson(),
          nowMs: 1,
        );
      }

      const classicAfter = CardState(
        itemId: 'i1',
        ease: 2.3,
        intervalDays: 6,
        dueEpochDay: 106,
        reps: 2,
        lapses: 0,
      );

      Future<void> gradeClassic(int id, CardState after, int ts) =>
          db.studyDao.recordGrade(
            courseRowId: id,
            before: CardState.initial('i1', const SrsDefaults(), 100),
            after: after,
            grade: Grade.good,
            tsMs: ts,
          );

      test('a grade under one scheduler leaves the other half as it was '
          'and marks itself the newer one', () async {
        final id = await importOne();
        await gradeClassic(id, classicAfter, 1);

        final fsrsAfter = scheduleFsrs(newFsrsCard('i1', 100), Grade.good, 100);
        await db.studyDao.recordGradeFsrs(
          courseRowId: id,
          before: newFsrsCard('i1', 100),
          after: fsrsAfter,
          grade: Grade.good,
          tsMs: 2,
        );

        var card = (await db.studyDao.loadCards(id))['i1']!;
        expect(card.classic!.intervalDays, classicAfter.intervalDays);
        expect(card.classic!.ease, classicAfter.ease);
        expect(card.fsrs, fsrsAfter);
        expect(card.lastGradedBy, Scheduler.fsrs);
        expect(card.progress.dueEpochDay, fsrsAfter.dueEpochDay);

        const classicAgain = CardState(
          itemId: 'i1',
          ease: 2.1,
          intervalDays: 14,
          dueEpochDay: 120,
          reps: 3,
          lapses: 0,
        );
        await gradeClassic(id, classicAgain, 3);
        card = (await db.studyDao.loadCards(id))['i1']!;
        expect(card.fsrs, fsrsAfter,
            reason: 'a classic grade never touches the FSRS half');
        expect(card.lastGradedBy, Scheduler.classic);
        expect(card.progress.intervalDays, 14);
      });

      test('a card graded only under FSRS loads, with no classic half',
          () async {
        final id = await importOne();
        final after = scheduleFsrs(newFsrsCard('i1', 100), Grade.good, 100);
        await db.studyDao.recordGradeFsrs(
          courseRowId: id,
          before: newFsrsCard('i1', 100),
          after: after,
          grade: Grade.good,
          tsMs: 1,
        );

        final card = (await db.studyDao.loadCards(id))['i1']!;
        expect(card.classic, isNull);
        expect(card.fsrs, after);
        expect(card.progress.started, isTrue);
        expect(await db.studyDao.loadClassicHalves(id), isEmpty);
      });

      test('a card never graded under FSRS has no FSRS half', () async {
        final id = await importOne();
        await gradeClassic(id, classicAfter, 1);
        final card = (await db.studyDao.loadCards(id))['i1']!;
        expect(card.fsrs, isNull);
        expect(card.lastGradedBy, Scheduler.classic);
      });

      test('a corrupt FSRS half reads as absent; the classic half carries '
          'the card, and the first FSRS grade seeds from it', () async {
        final id = await importOne();
        await db
            .into(db.cards)
            .insert(
              CardsCompanion.insert(
                courseId: id,
                itemId: 'i1',
                stateJson:
                    '{"ease":2.5,"intervalDays":5,"dueEpochDay":105,"reps":1,'
                    '"lapses":0,"fsrsStability":"not-a-number",'
                    '"fsrsDifficulty":5,"lastGradedBy":"fsrs"}',
              ),
            );

        final card = (await db.studyDao.loadCards(id))['i1']!;
        expect(card.fsrs, isNull);
        expect(card.lastGradedBy, Scheduler.classic);
        expect(card.fsrsToGradeFrom(100).stability, closeTo(5, 1e-9));
      });

      test('recordGradeFsrs APPENDS one revlog row too, day-interval fields '
          'reused for the FSRS interval', () async {
        final id = await importOne();
        final state = newFsrsCard('i1', 100);
        final next = scheduleFsrs(state, Grade.good, 100);
        await db.studyDao.recordGradeFsrs(
          courseRowId: id,
          before: state,
          after: next,
          grade: Grade.good,
          tsMs: 5,
        );

        final log = await db.studyDao.revlogOf(id);
        expect(log, hasLength(1));
        expect(log[0].grade, 'good');
        expect(log[0].intervalAfterDays, next.dueEpochDay - 100);
      });

      test('switching to FSRS seeds from classic history (stability := '
          'interval), never a bare fresh card', () async {
        final id = await importOne();
        const classic = CardState(
          itemId: 'i1',
          ease: 2.3,
          intervalDays: 14,
          dueEpochDay: 120,
          reps: 3,
          lapses: 1,
        );
        await gradeClassic(id, classic, 1);

        final seeded = (await db.studyDao.loadCards(id))['i1']!
            .fsrsToGradeFrom(120);
        expect(seeded.stability, closeTo(14, 1e-9));
        expect(seeded.reps, 3);
        expect(seeded.lastReviewEpochDay, 106);
      });

      test('once FSRS graded last, its stored state is graded from as is',
          () async {
        final id = await importOne();
        await gradeClassic(id, classicAfter, 1);
        final first = (await db.studyDao.loadCards(id))['i1']!
            .fsrsToGradeFrom(106);
        final graded = scheduleFsrs(first, Grade.good, 106);
        await db.studyDao.recordGradeFsrs(
          courseRowId: id,
          before: first,
          after: graded,
          grade: Grade.good,
          tsMs: 2,
        );

        final second = (await db.studyDao.loadCards(id))['i1']!
            .fsrsToGradeFrom(graded.dueEpochDay);
        expect(second, graded);
      });

      test('switching back to Classic after FSRS grading seeds classic from '
          'the newer FSRS half', () async {
        final id = await importOne();
        await gradeClassic(id, classicAfter, 1);
        final fsrsBefore = (await db.studyDao.loadCards(id))['i1']!
            .fsrsToGradeFrom(106);
        final fsrsAfter = scheduleFsrs(fsrsBefore, Grade.good, 106);
        await db.studyDao.recordGradeFsrs(
          courseRowId: id,
          before: fsrsBefore,
          after: fsrsAfter,
          grade: Grade.good,
          tsMs: 2,
        );

        final classic = (await db.studyDao.loadCards(id))['i1']!
            .classicToGradeFrom();
        expect(classic.intervalDays, fsrsAfter.dueEpochDay - 106);
        expect(classic.intervalDays, greaterThan(classicAfter.intervalDays),
            reason: 'the FSRS review grew the interval; switching back '
                'must not throw that away');
        expect(classic.dueEpochDay, fsrsAfter.dueEpochDay);
      });
    });
  });

  group('schema migration v2 → v3', () {
    test('a v2 database gains the study tables and keeps its data', () async {
      final dir = Directory.systemTemp.createTempSync('trellis-migration-v3');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/v2.sqlite');

      // Build a real v2 file from drift's own DDL: create at the current
      // version, drop exactly what v3 added, stamp user_version 2. v3 is
      // purely additive, so what remains IS the v2 schema. `createTable`
      // migrations are idempotent (CREATE TABLE IF NOT EXISTS) so later
      // tables (jobs, word_ledger, household_pin, queue, captures,
      // daily_review_cards, translation_sentences) surviving from the live
      // schema don't matter here — but every `addColumn` since (v7's
      // prefer_system_voice, v8's next_page_url, v9's scheduler, v12's
      // Campaign 1 columns, v13's show_translation_layer, v15's
      // rules/dedup columns, v16's DSP columns, v17's audiobook file_idx)
      // is NOT idempotent, so those columns have to go too, or a database
      // claiming to be v2 would silently already carry them. v2 is exactly
      // where feeds/episodes/player_positions were introduced, so v8's,
      // v12's, v15's, v16's and v17's columns on those tables are in scope
      // here too. `captures.file_idx` (also v17) is NOT dropped below —
      // `captures` itself doesn't exist until v10, so a v2 snapshot never
      // had it to strip.
      final seed = AppDatabase.forTesting(NativeDatabase(file));
      await seed.profilesDao.create('Ada');
      await seed.spineDao.insertWork(
        profileId: 1,
        kind: 'book',
        title: 'Kept Book',
        persistence: 'work',
        firstSeenEpochDay: 100,
      );
      await seed.close();
      final v2 = raw.sqlite3.open(file.path);
      v2.execute('''
        $stripV26
        ALTER TABLE feeds DROP COLUMN image_url;
        DROP TABLE revlog;
        DROP TABLE cards;
        DROP TABLE courses;
        ALTER TABLE profiles DROP COLUMN prefer_system_voice;
        ALTER TABLE profiles DROP COLUMN scheduler;
        ALTER TABLE feeds DROP COLUMN next_page_url;
        ALTER TABLE profiles DROP COLUMN keep_finished_in_queue;
        ALTER TABLE feeds DROP COLUMN speed_override;
        ALTER TABLE feeds DROP COLUMN skip_intro_seconds;
        ALTER TABLE feeds DROP COLUMN skip_outro_seconds;
        ALTER TABLE feeds DROP COLUMN keep_latest_audio;
        ALTER TABLE episodes DROP COLUMN archived_at_ms;
        ALTER TABLE works DROP COLUMN show_translation_layer;
        ALTER TABLE works DROP COLUMN active_translation_lang;
        ALTER TABLE feeds DROP COLUMN rules_json;
        ALTER TABLE episodes DROP COLUMN dedup_reason;
        ALTER TABLE episodes DROP COLUMN duplicate_of_work_id;
        ALTER TABLE feeds DROP COLUMN dsp_enabled;
        ALTER TABLE episodes DROP COLUMN dsp_original_duration_ms;
        ALTER TABLE episodes DROP COLUMN dsp_processed_duration_ms;
        ALTER TABLE profiles DROP COLUMN dsp_global_default;
        ALTER TABLE player_positions DROP COLUMN file_idx;
        ALTER TABLE profiles DROP COLUMN reader_prefs_json;
        DROP TABLE reading_days;
        ALTER TABLE episodes DROP COLUMN finished_at_ms;
        ALTER TABLE episodes DROP COLUMN image_url;
        ALTER TABLE feeds DROP COLUMN sort_oldest_first;
        ALTER TABLE feeds DROP COLUMN origin;
        PRAGMA user_version = 2;
      ''');
      v2.dispose();

      final migrated = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(migrated.close);

      // Old data survives…
      final work = (await migrated.spineDao.worksOf(1)).single;
      expect(work.title, 'Kept Book');

      // …and the new tables exist and work.
      final id = await migrated.studyDao.importCourse(
        profileId: 1,
        raw: courseJson(),
        nowMs: 7,
      );
      await migrated.studyDao.recordGrade(
        courseRowId: id,
        before: CardState.initial('i1', const SrsDefaults(), 100),
        after: scheduleSm2(
          CardState.initial('i1', const SrsDefaults(), 100),
          Grade.good,
          100,
        ),
        grade: Grade.good,
        tsMs: 8,
      );
      expect(await migrated.studyDao.revlogOf(id), hasLength(1));
    });
  });
}
