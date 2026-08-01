import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw;
import 'package:study_core/study_core.dart';
import 'package:trellis/db/database.dart';

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
        final cards = await db.studyDao.loadCardStates(id);
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

      expect(await db.studyDao.loadCardStates(id), isEmpty);

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

      final loaded = (await db.studyDao.loadCardStates(id))['i1']!;
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

        final cards = await db.studyDao.loadCardStates(id);
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
        final stored = (await db.studyDao.loadCardStates(id))['i1']!;
        expect(folded.intervalDays, stored.intervalDays);
        expect(folded.ease, stored.ease);
        expect(folded.reps, stored.reps);
        expect(folded.lapses, stored.lapses);
      },
    );

    test('loadCardStates skips a malformed row individually, the rest of '
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

      final cards = await db.studyDao.loadCardStates(id);
      expect(
        cards.keys,
        ['i1'],
        reason:
            'the malformed i2 entry is skipped, not thrown for the '
            'whole course',
      );
      expect(cards['i1']!.intervalDays, 6);
    });

    group('FSRS (the study crown, opt-in, additive JSON keys)', () {
      test(
        'grading under FSRS preserves the classic half of an existing '
        'card untouched, and vice versa — the lossy-switch-back law '
        'depends on each half staying frozen while the other is active',
        () async {
          final profileId = await seedProfile();
          final id = await db.studyDao.importCourse(
            profileId: profileId,
            raw: courseJson(),
            nowMs: 1,
          );

          const classicAfter = CardState(
            itemId: 'i1',
            ease: 2.3,
            intervalDays: 6,
            dueEpochDay: 106,
            reps: 2,
            lapses: 0,
          );
          await db.studyDao.recordGrade(
            courseRowId: id,
            before: CardState.initial('i1', const SrsDefaults(), 100),
            after: classicAfter,
            grade: Grade.good,
            tsMs: 1,
          );

          // Now grade the SAME card under FSRS.
          final fsrsAfter = scheduleFsrs(
            newFsrsCard('i1', 100),
            Grade.good,
            100,
          );
          await db.studyDao.recordGradeFsrs(
            courseRowId: id,
            before: newFsrsCard('i1', 100),
            after: fsrsAfter,
            grade: Grade.good,
            tsMs: 2,
          );

          // The classic half is exactly what it was before the FSRS grade —
          // frozen, not merged, not recomputed.
          final classicStored = (await db.studyDao.loadCardStates(id))['i1']!;
          expect(classicStored.ease, classicAfter.ease);
          expect(classicStored.intervalDays, classicAfter.intervalDays);
          expect(classicStored.dueEpochDay, classicAfter.dueEpochDay);

          // The FSRS half is there too.
          final fsrsStored = (await db.studyDao.loadFsrsCardStates(
            id,
            100,
          ))['i1']!;
          expect(fsrsStored.stability, fsrsAfter.stability);
          expect(fsrsStored.difficulty, fsrsAfter.difficulty);

          // Grading classic again must not erase the FSRS half either.
          const classicAgain = CardState(
            itemId: 'i1',
            ease: 2.1,
            intervalDays: 14,
            dueEpochDay: 120,
            reps: 3,
            lapses: 0,
          );
          await db.studyDao.recordGrade(
            courseRowId: id,
            before: classicAfter,
            after: classicAgain,
            grade: Grade.good,
            tsMs: 3,
          );
          final fsrsAfterClassicRegrade = (await db.studyDao.loadFsrsCardStates(
            id,
            100,
          ))['i1']!;
          expect(
            fsrsAfterClassicRegrade.stability,
            fsrsAfter.stability,
            reason: 'a classic grade must never touch the FSRS half',
          );
        },
      );

      test('loadFsrsCardStates: a card never touched by FSRS returns '
          'FsrsCardState.initial (missing -> new, not a throw)', () async {
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
          tsMs: 1,
        );

        final fsrs = (await db.studyDao.loadFsrsCardStates(id, 100))['i1']!;
        expect(fsrs.reps, 0);
        expect(fsrs.stability, 0);
      });

      test('loadFsrsCardStates: a corrupt fsrs blob also degrades to new, '
          'never throws', () async {
        final profileId = await seedProfile();
        final id = await db.studyDao.importCourse(
          profileId: profileId,
          raw: courseJson(),
          nowMs: 1,
        );
        await db
            .into(db.cards)
            .insert(
              CardsCompanion.insert(
                courseId: id,
                itemId: 'i1',
                stateJson:
                    '{"ease":2.5,"intervalDays":1,"dueEpochDay":101,"reps":1,'
                    '"lapses":0,"fsrsStability":"not-a-number"}',
              ),
            );

        final fsrs = (await db.studyDao.loadFsrsCardStates(id, 100))['i1']!;
        expect(fsrs.reps, 0, reason: 'a corrupt FSRS half is treated as new');
      });

      test('recordGradeFsrs APPENDS one revlog row too, day-interval fields '
          'reused for the FSRS interval', () async {
        final profileId = await seedProfile();
        final id = await db.studyDao.importCourse(
          profileId: profileId,
          raw: courseJson(),
          nowMs: 1,
        );

        var state = newFsrsCard('i1', 100);
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

      group('fsrsStateToGradeFrom — lazy seeding on first FSRS grade', () {
        test('a card with real classic history and no FSRS row yet: seeds '
            'from the classic state (stability := interval, difficulty := '
            'the ease map), not a bare FsrsCardState.initial', () async {
          final profileId = await seedProfile();
          final id = await db.studyDao.importCourse(
            profileId: profileId,
            raw: courseJson(),
            nowMs: 1,
          );
          const classic = CardState(
            itemId: 'i1',
            ease: 2.3,
            intervalDays: 14,
            dueEpochDay: 120,
            reps: 3,
            lapses: 1,
          );
          await db.studyDao.recordGrade(
            courseRowId: id,
            before: CardState.initial('i1', const SrsDefaults(), 100),
            after: classic,
            grade: Grade.good,
            tsMs: 1,
          );

          final seeded = await db.studyDao.fsrsStateToGradeFrom(
            courseRowId: id,
            itemId: 'i1',
            classicBefore: classic,
            todayEpochDay: 100,
          );

          expect(
            seeded.stability,
            closeTo(14, 1e-9),
            reason: 'seedFsrsFromClassic\'s own law: stability := interval',
          );
          expect(
            seeded.reps,
            3,
            reason: 'the seed carries the classic reps/lapses forward too',
          );
        });

        test(
          'a genuinely fresh item (never graded under either scheduler): '
          'seeding does not corrupt the first-review grade — scheduleFsrs '
          'still computes S0/D0 from the grade, not the seeded placeholder',
          () async {
            final profileId = await seedProfile();
            final id = await db.studyDao.importCourse(
              profileId: profileId,
              raw: courseJson(),
              nowMs: 1,
            );
            final freshClassic = CardState.initial(
              'i1',
              const SrsDefaults(),
              100,
            );

            final seeded = await db.studyDao.fsrsStateToGradeFrom(
              courseRowId: id,
              itemId: 'i1',
              classicBefore: freshClassic,
              todayEpochDay: 100,
            );
            final graded = scheduleFsrs(seeded, Grade.good, 100);

            expect(
              graded.stability,
              closeTo(kFsrsDefaultWeights[2], 1e-9),
              reason:
                  'the first-review branch (reps==0) computes S0(good) '
                  'from the grade alone, ignoring whatever the seed set',
            );
          },
        );

        test('once a real FSRS row exists, later calls return it — never '
            're-seeds a card FSRS has already touched', () async {
          final profileId = await seedProfile();
          final id = await db.studyDao.importCourse(
            profileId: profileId,
            raw: courseJson(),
            nowMs: 1,
          );
          final first = await db.studyDao.fsrsStateToGradeFrom(
            courseRowId: id,
            itemId: 'i1',
            classicBefore: CardState.initial('i1', const SrsDefaults(), 100),
            todayEpochDay: 100,
          );
          final graded = scheduleFsrs(first, Grade.good, 100);
          await db.studyDao.recordGradeFsrs(
            courseRowId: id,
            before: first,
            after: graded,
            grade: Grade.good,
            tsMs: 1,
          );

          final second = await db.studyDao.fsrsStateToGradeFrom(
            courseRowId: id,
            itemId: 'i1',
            // A deliberately different classic state — if this were used,
            // the seed would differ. It must be ignored.
            classicBefore: const CardState(
              itemId: 'i1',
              ease: 1.3,
              intervalDays: 99,
              dueEpochDay: 999,
              reps: 9,
              lapses: 9,
            ),
            todayEpochDay: graded.dueEpochDay,
          );

          expect(
            second.stability,
            graded.stability,
            reason: 'the real stored FSRS state wins over any reseed',
          );
        });

        test(
          'a corrupt FSRS half also falls back to seeding, not a throw',
          () async {
            final profileId = await seedProfile();
            final id = await db.studyDao.importCourse(
              profileId: profileId,
              raw: courseJson(),
              nowMs: 1,
            );
            await db
                .into(db.cards)
                .insert(
                  CardsCompanion.insert(
                    courseId: id,
                    itemId: 'i1',
                    stateJson:
                        '{"ease":2.5,"intervalDays":5,"dueEpochDay":105,'
                        '"reps":1,"lapses":0,"fsrsStability":"not-a-number"}',
                  ),
                );
            const classic = CardState(
              itemId: 'i1',
              ease: 2.5,
              intervalDays: 5,
              dueEpochDay: 105,
              reps: 1,
              lapses: 0,
            );

            final seeded = await db.studyDao.fsrsStateToGradeFrom(
              courseRowId: id,
              itemId: 'i1',
              classicBefore: classic,
              todayEpochDay: 100,
            );

            expect(seeded.stability, closeTo(5, 1e-9));
          },
        );
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
