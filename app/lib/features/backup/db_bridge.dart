import 'package:backup_core/backup_core.dart';
import 'package:drift/drift.dart';
import 'package:study_core/study_core.dart' as study;

import '../../db/database.dart';

/// The Drift <-> backup_core seam. backup_core deliberately never sees a
/// database — it speaks DB-agnostic row maps — so this bridge is the ONE
/// place the app's schema and the canonical payload shape meet.
///
/// **Own backups are full-replace.** The canonical payload carries the whole
/// `profiles` table and every row's raw integer id (the FK edges between
/// works, segments, cards and revlog are those ids verbatim). Merging two
/// devices' autoincrement id spaces cannot be done without rewriting every
/// edge; replacing wholesale keeps them true by construction. Donor imports
/// are the opposite — they carry donor-scoped string ids and MERGE into one
/// profile, because a migration lands beside a life already in progress.
///
/// **Two riders keep the canonical 11 tables honest.** The schema grew
/// `episodes` and `wordLedger` after the payload shape froze, and each is
/// metadata OF a canonical row: river metadata rides on its work row under
/// `episode` (an episode IS a spine work — see [Episodes]), and the word
/// ledger rides on its profile row under `wordLedger` (the ledger is the
/// user's own collection, ADR-0003 law 2). `Row.fromJson` ignores unknown
/// keys, so the riders cost nothing on the way back in.
///
/// The `jobs` table never travels: checkpoints name files on THIS device.
class DbBridge {
  DbBridge(this.db);

  final AppDatabase db;

  static const int _msPerDay = 86400000;

  // ── Own backup: export ─────────────────────────────────────────────

  /// The whole device as canonical row maps, deterministically ordered so
  /// two exports of equal databases are deeply equal (the round-trip test's
  /// definition of "same device").
  Future<RowTables> exportTables() async {
    List<Map<String, Object?>> rows(List<dynamic> data) => [
          for (final d in data)
            Map<String, Object?>.from((d as DataClass).toJson())
        ];

    final episodes = await (db.select(db.episodes)
          ..orderBy([(e) => OrderingTerm.asc(e.workId)]))
        .get();
    final episodeByWork = {for (final e in episodes) e.workId: e.toJson()};
    final ledger = await (db.select(db.wordLedger)
          ..orderBy([(w) => OrderingTerm.asc(w.id)]))
        .get();
    final ledgerByProfile = <int, List<Map<String, Object?>>>{};
    for (final w in ledger) {
      ledgerByProfile
          .putIfAbsent(w.profileId, () => [])
          .add(Map<String, Object?>.from(w.toJson()));
    }

    final profiles = await (db.select(db.profiles)
          ..orderBy([(p) => OrderingTerm.asc(p.id)]))
        .get();
    final works = await (db.select(db.works)
          ..orderBy([(w) => OrderingTerm.asc(w.id)]))
        .get();

    return {
      'profiles': [
        for (final p in profiles)
          {
            ...p.toJson(),
            if (ledgerByProfile.containsKey(p.id))
              'wordLedger': ledgerByProfile[p.id],
          }
      ],
      'works': [
        for (final w in works)
          {
            ...w.toJson(),
            if (episodeByWork.containsKey(w.id))
              'episode': episodeByWork[w.id],
          }
      ],
      'segments': rows(await (db.select(db.segments)
            ..orderBy([
              (s) => OrderingTerm.asc(s.workId),
              (s) => OrderingTerm.asc(s.idx)
            ]))
          .get()),
      'layers': rows(await (db.select(db.layers)
            ..orderBy([
              (l) => OrderingTerm.asc(l.workId),
              (l) => OrderingTerm.asc(l.segmentIdx),
              (l) => OrderingTerm.asc(l.lang)
            ]))
          .get()),
      'alignments': rows(await (db.select(db.alignments)
            ..orderBy([
              (a) => OrderingTerm.asc(a.workId),
              (a) => OrderingTerm.asc(a.segmentIdx)
            ]))
          .get()),
      'positions': rows(await (db.select(db.positions)
            ..orderBy([
              (p) => OrderingTerm.asc(p.profileId),
              (p) => OrderingTerm.asc(p.workId)
            ]))
          .get()),
      'feeds': rows(await (db.select(db.feeds)
            ..orderBy([(f) => OrderingTerm.asc(f.id)]))
          .get()),
      'courses': rows(await (db.select(db.courses)
            ..orderBy([(c) => OrderingTerm.asc(c.id)]))
          .get()),
      'cards': rows(await (db.select(db.cards)
            ..orderBy([(c) => OrderingTerm.asc(c.id)]))
          .get()),
      'revlog': rows(await (db.select(db.revlog)
            ..orderBy([(r) => OrderingTerm.asc(r.id)]))
          .get()),
      'playerPositions': rows(await (db.select(db.playerPositions)
            ..orderBy([
              (p) => OrderingTerm.asc(p.profileId),
              (p) => OrderingTerm.asc(p.workId)
            ]))
          .get()),
    };
  }

  // ── Own backup: restore ────────────────────────────────────────────

  /// Replaces this device's data with [payload], wholesale, in ONE
  /// transaction — a restore that fails half-way leaves the device exactly
  /// as it was (the donor's index-last discipline, upgraded to atomicity).
  Future<void> restoreFullReplace(DecodedPayload payload) {
    Map<String, dynamic> cast(Map<String, Object?> row) =>
        Map<String, dynamic>.from(row);

    return db.transaction(() async {
      // Children before parents; `jobs` is device-local and untouched.
      for (final table in <TableInfo>[
        db.revlog,
        db.cards,
        db.courses,
        db.wordLedger,
        db.playerPositions,
        db.episodes,
        db.positions,
        db.alignments,
        db.layers,
        db.segments,
        db.feeds,
        db.works,
        db.profiles,
      ]) {
        await db.delete(table).go();
      }

      final t = payload.tables;
      for (final row in t['profiles']!) {
        await db.into(db.profiles).insert(Profile.fromJson(cast(row)));
      }
      for (final row in t['works']!) {
        await db.into(db.works).insert(Work.fromJson(cast(row)));
      }
      for (final row in t['feeds']!) {
        await db.into(db.feeds).insert(Feed.fromJson(cast(row)));
      }
      // Riders after their parents (episodes reference works AND feeds).
      for (final row in t['works']!) {
        final episode = row['episode'];
        if (episode is Map) {
          await db.into(db.episodes).insert(
              Episode.fromJson(Map<String, dynamic>.from(episode)));
        }
      }
      for (final row in t['profiles']!) {
        final ledger = row['wordLedger'];
        if (ledger is List) {
          for (final entry in ledger) {
            if (entry is Map) {
              await db.into(db.wordLedger).insert(
                  WordLedgerRow.fromJson(Map<String, dynamic>.from(entry)));
            }
          }
        }
      }
      for (final row in t['segments']!) {
        await db.into(db.segments).insert(Segment.fromJson(cast(row)));
      }
      for (final row in t['layers']!) {
        await db.into(db.layers).insert(Layer.fromJson(cast(row)));
      }
      for (final row in t['alignments']!) {
        await db.into(db.alignments).insert(Alignment.fromJson(cast(row)));
      }
      for (final row in t['positions']!) {
        await db.into(db.positions).insert(Position.fromJson(cast(row)));
      }
      for (final row in t['playerPositions']!) {
        await db
            .into(db.playerPositions)
            .insert(PlayerPosition.fromJson(cast(row)));
      }
      // Course rows re-enter verbatim: the strict parser accepted this text
      // on the source device, and the AEAD tag vouches nothing changed.
      for (final row in t['courses']!) {
        await db.into(db.courses).insert(CourseRow.fromJson(cast(row)));
      }
      for (final row in t['cards']!) {
        await db.into(db.cards).insert(CardRow.fromJson(cast(row)));
      }
      for (final row in t['revlog']!) {
        await db.into(db.revlog).insert(RevlogRow.fromJson(cast(row)));
      }
    });
  }

  // ── Donor merges ───────────────────────────────────────────────────

  /// Merges a decoded donor Trellis backup into [profileId]: course bodies
  /// go through [StudyDao.importCourse] (the strict parser or nothing),
  /// SM-2 card state lands 1:1 — including progress for a course this
  /// device already has (the donor's bundled-course case). Returns the
  /// engine's report extended with what actually found a home.
  Future<MigrationReport> applyTrellis(
    TrellisImportResult result, {
    required int profileId,
    required int nowMs,
  }) {
    return db.transaction(() async {
      final imported = <String, int>{};
      final skipped = Map<String, int>.of(result.report.skipped);
      void skip(String reason) =>
          skipped[reason] = (skipped[reason] ?? 0) + 1;

      final rowIdByDonorId = <String, int>{};
      for (final row in result.tables['courses'] ?? const []) {
        final donorId = row['id'] as String;
        final body = row['body'] as String;
        try {
          rowIdByDonorId[donorId] = await db.studyDao
              .importCourse(profileId: profileId, raw: body, nowMs: nowMs);
          imported['courses'] = (imported['courses'] ?? 0) + 1;
        } on FormatException {
          skip("a course this app's parser refused");
        }
      }

      for (final row in result.tables['cards'] ?? const []) {
        final donorCourseId = row['courseId'] as String;
        var rowId = rowIdByDonorId[donorCourseId];
        // Bundled-course progress: the body never travelled, but this
        // device may hold the same course — the progress is the user's.
        rowId ??= (await (db.select(db.courses)
                  ..where((c) =>
                      c.profileId.equals(profileId) &
                      c.courseId.equals(donorCourseId)))
                .getSingleOrNull())
            ?.id;
        if (rowId == null) {
          skip('progress for a course not on this device');
          continue;
        }
        await _upsertCardState(
            courseRowId: rowId,
            state: study.CardState(
              itemId: row['itemId'] as String,
              ease: (row['ease'] as num).toDouble(),
              intervalDays: row['intervalDays'] as int,
              dueEpochDay: row['dueEpochDay'] as int,
              reps: row['reps'] as int,
              lapses: row['lapses'] as int,
            ));
        imported['cards'] = (imported['cards'] ?? 0) + 1;
      }

      return MigrationReport(
          imported: imported,
          skipped: skipped,
          dropped: result.report.dropped);
    });
  }

  /// Merges a decoded ohPrimer export into [profileId]. Named mappings:
  ///
  ///  - books -> works + segments + a reading position (the donor's global
  ///    word offset arrives under segment 0 and the reader clamps —
  ///    backup_core names this loss);
  ///  - **vocabulary extracts -> the word ledger**: a `focusWord` extract is
  ///    exactly what the ledger keeps — a word the user's hand set aside
  ///    while reading (ADR-0003 law 2). Its SM-2 timers stay behind: the
  ///    ledger keeps the words, not the schedules — named in `dropped`.
  ///  - passage extracts and their review history have no home here (no
  ///    course exists to hold them) — counted in `skipped`, never silent;
  ///  - the donor profile row is NOT applied: the merge lands in a profile
  ///    the user already named here, and this app keeps no reading stats.
  Future<MigrationReport> applyPrimer(
    PrimerImportResult result, {
    required int profileId,
    required int nowMs,
  }) {
    return db.transaction(() async {
      final imported = <String, int>{};
      final skipped = Map<String, int>.of(result.report.skipped);
      void skip(String reason, [int count = 1]) {
        if (count <= 0) return;
        skipped[reason] = (skipped[reason] ?? 0) + count;
      }

      void count(String table, [int by = 1]) =>
          imported[table] = (imported[table] ?? 0) + by;

      // Works. The donor deduped by (filename, size); those columns do not
      // exist here, so a work that already arrived is recognized the way a
      // person would — same title, same kind.
      final existing = await db.spineDao.worksOf(profileId);
      final workIdByDonorId = <String, int>{};
      for (final row in result.tables['works'] ?? const []) {
        final donorId = row['id'] as String;
        final title = row['title'] as String? ?? 'Untitled';
        final kind = row['kind'] as String? ?? 'book';
        if (existing.any((w) => w.title == title && w.kind == kind)) {
          skip('a work already in this library');
          continue;
        }
        final addedAt = row['addedAt'] as int?;
        final source = row['source'];
        workIdByDonorId[donorId] = await db.spineDao.insertWork(
            profileId: profileId,
            kind: kind,
            title: title,
            persistence: 'work', // a kept book is a work; ephemera never came
            firstSeenEpochDay:
                (addedAt ?? nowMs) ~/ _msPerDay,
            sourceUrl: source is Map && source['url'] is String
                ? source['url'] as String
                : null,
            lang: row['detectedLang'] as String?);
        count('works');
      }

      final segmentsByWork = <int, List<({int idx, String kind, String text})>>{};
      for (final row in result.tables['segments'] ?? const []) {
        final workId = workIdByDonorId[row['workId']];
        if (workId == null) continue; // its work was already here
        segmentsByWork.putIfAbsent(workId, () => []).add((
          idx: row['idx'] as int,
          kind: row['kind'] as String,
          text: row['text'] as String? ?? '',
        ));
      }
      for (final entry in segmentsByWork.entries) {
        await db.spineDao.insertSegments(entry.key, entry.value);
        count('segments', entry.value.length);
      }

      for (final row in result.tables['positions'] ?? const []) {
        final workId = workIdByDonorId[row['workId']];
        if (workId == null) continue;
        // Direct insert, not savePosition: the donor knew when the book was
        // last read, and that timestamp is worth keeping.
        await db.into(db.positions).insertOnConflictUpdate(
            PositionsCompanion.insert(
                profileId: profileId,
                workId: workId,
                segmentIdx: row['segmentIdx'] as int? ?? 0,
                wordIdx: row['wordIdx'] as int? ?? 0,
                lastModality: row['lastModality'] as String? ?? 'read',
                updatedAtMs: row['updatedAt'] as int? ?? nowMs));
        count('positions');
      }

      for (final row in result.tables['feeds'] ?? const []) {
        final url = row['url'] as String;
        if (await db.feedsDao.feedByUrl(profileId, url) != null) {
          skip('a feed already subscribed here');
          continue;
        }
        await db.feedsDao.insertFeed(
            profileId: profileId,
            url: url,
            title: row['title'] as String? ?? url);
        count('feeds');
      }

      // Extracts: vocabulary joins the word ledger; the rest is counted out.
      var historySkipped = 0;
      for (final row in result.tables['cards'] ?? const []) {
        final word = row['focusWord'] as String?;
        if (word == null || word.isEmpty) {
          skip('a passage extract with no course to hold it');
          continue;
        }
        final already = await (db.select(db.wordLedger)
              ..where((w) =>
                  w.profileId.equals(profileId) & w.word.equals(word)))
            .getSingleOrNull();
        if (already != null) {
          skip('a word already in the ledger');
          continue;
        }
        await db.ledgerDao.add(
            profileId: profileId,
            word: word,
            sourceWorkId: workIdByDonorId[row['workId']],
            nowMs: row['createdAt'] as int? ?? nowMs);
        count('wordLedger');
      }
      historySkipped = (result.tables['revlog'] ?? const []).length;
      skip('review history for extracts', historySkipped);

      return MigrationReport(
        imported: imported,
        skipped: skipped,
        dropped: [
          ...result.report.dropped,
          'Reading stats stay with the old app — this one counts from here.',
          'Vocabulary extracts joined the word ledger; the ledger keeps the '
              'words, not their review schedules.',
        ],
      );
    });
  }

  /// Donor progress wins over whatever state the card had here: a restore
  /// that quietly keeps the older of two schedules would be a silent loss.
  Future<void> _upsertCardState(
      {required int courseRowId, required study.CardState state}) async {
    final existing = await (db.select(db.cards)
          ..where((c) =>
              c.courseId.equals(courseRowId) & c.itemId.equals(state.itemId)))
        .getSingleOrNull();
    if (existing != null) {
      await (db.update(db.cards)..where((c) => c.id.equals(existing.id)))
          .write(CardsCompanion(stateJson: Value(encodeCardState(state))));
    } else {
      await db.into(db.cards).insert(CardsCompanion.insert(
          courseId: courseRowId,
          itemId: state.itemId,
          stateJson: encodeCardState(state)));
    }
  }
}
