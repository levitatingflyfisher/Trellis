import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:jobs_core/jobs_core.dart' as jobs;
import 'package:loom_core/loom_core.dart' as core;
import 'package:study_core/study_core.dart' as study;

part 'database.g.dart';

/// Spine storage (ADR-0002). Enums travel as strings so the schema never
/// couples to Dart enum indices.
class Profiles extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();

  /// The speak-mode voice preference (ADR-0006's settings escape): false
  /// (the default) lets the reader use a neural voice whenever one is
  /// on-device; true pins this profile to the system voice on purpose. A
  /// profile with no neural voice ever downloaded is unaffected either
  /// way — the reader falls back to the system voice regardless, since
  /// there is nothing to prefer away from.
  BoolColumn get preferSystemVoice =>
      boolean().withDefault(const Constant(false))();
}

class Works extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get profileId => integer().references(Profiles, #id)();
  TextColumn get kind => text()();
  TextColumn get title => text()();
  TextColumn get sourceUrl => text().nullable()();
  TextColumn get lang => text().nullable()();
  TextColumn get persistence => text()();
  IntColumn get firstSeenEpochDay => integer()();
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
  IntColumn get finishedEpochDay => integer().nullable()();
}

class Segments extends Table {
  IntColumn get workId => integer().references(Works, #id)();
  IntColumn get idx => integer()();
  TextColumn get kind => text()();
  TextColumn get body => text()();
  @override
  Set<Column> get primaryKey => {workId, idx};
}

class Layers extends Table {
  IntColumn get workId => integer().references(Works, #id)();
  IntColumn get segmentIdx => integer()();
  TextColumn get lang => text()();
  TextColumn get kind => text()();
  TextColumn get body => text()();
  @override
  Set<Column> get primaryKey => {workId, segmentIdx, lang};
}

class Alignments extends Table {
  IntColumn get workId => integer().references(Works, #id)();
  IntColumn get segmentIdx => integer()();
  IntColumn get tStartMs => integer()();
  IntColumn get tEndMs => integer()();
  BlobColumn get wordTimings => blob().nullable()();
  @override
  Set<Column> get primaryKey => {workId, segmentIdx};
}

class Positions extends Table {
  IntColumn get profileId => integer().references(Profiles, #id)();
  IntColumn get workId => integer().references(Works, #id)();
  IntColumn get segmentIdx => integer()();
  IntColumn get wordIdx => integer()();
  TextColumn get lastModality => text()();
  IntColumn get updatedAtMs => integer()();
  @override
  Set<Column> get primaryKey => {profileId, workId};
}

/// One subscription (P2). Validators (etag/lastModified) and the refresh
/// breaker travel with the row; the breaker's transition rules stay pure in
/// comms_core — [breakerJson] is its persisted form.
class Feeds extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get profileId => integer().references(Profiles, #id)();
  TextColumn get url => text()();
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get etag => text().nullable()();
  TextColumn get lastModified => text().nullable()();
  TextColumn get breakerJson => text().withDefault(const Constant('{}'))();
  BoolColumn get autoDownload => boolean().withDefault(const Constant(false))();
}

/// River metadata for a feed item. The item itself IS a spine work
/// (kind episode/article, persistence ephemeron, sourceUrl = enclosure or
/// link — ADR-0002); this row carries only what the river needs: identity
/// for dedupe (guid), the ONE ordering key (publishedAtMs), the unread dot
/// (readAtMs) and playback metadata.
class Episodes extends Table {
  IntColumn get workId => integer().references(Works, #id)();
  IntColumn get feedId => integer().references(Feeds, #id)();
  TextColumn get guid => text()();
  TextColumn get enclosureUrl => text().nullable()();
  IntColumn get durationMs => integer().nullable()();
  IntColumn get publishedAtMs => integer()();
  IntColumn get readAtMs => integer().nullable()();
  @override
  Set<Column> get primaryKey => {workId};
}

/// Raw listening position for works WITHOUT alignments. When alignments
/// exist the player projects time → segmentIdx and writes the same
/// [Positions] row the reader reads (the cursor law); this table is the
/// honest fallback until a transcript exists.
class PlayerPositions extends Table {
  IntColumn get profileId => integer().references(Profiles, #id)();
  IntColumn get workId => integer().references(Works, #id)();
  IntColumn get tMs => integer()();
  IntColumn get updatedAtMs => integer()();
  @override
  Set<Column> get primaryKey => {profileId, workId};
}

/// The word ledger: words the user's hand set aside while reading or
/// listening. Dedupe lives in the schema — (profileId, word) is unique with
/// [word] carrying COLLATE NOCASE, so every code path folds case in SQLite
/// itself. [sourceWorkId] is provenance only and declares ON DELETE SET
/// NULL: works come and go (ephemera decay, library removal), but the
/// ledger is the user's own collection (the promotion principle, ADR-0003
/// law 2) — deleting a work degrades provenance to null instead of draining
/// the notebook the way CASCADE silently would.
@DataClassName('WordLedgerRow')
class WordLedger extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get profileId => integer().references(Profiles, #id)();
  TextColumn get word => text().customConstraint('NOT NULL COLLATE NOCASE')();
  TextColumn get lang => text().nullable()();
  IntColumn get sourceWorkId => integer()
      .nullable()
      .references(Works, #id, onDelete: KeyAction.setNull)();
  IntColumn get addedAtMs => integer()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {profileId, word}
      ];
}

/// One imported `.ohcourse` per reader (P0/§6 study slice). [raw] is the file
/// text VERBATIM — study_core's strict parser is the single authority over
/// its meaning, and it must have accepted the text before a row may exist.
/// [courseId] is the course's own id from the file, kept for per-profile
/// dedupe; [id] is this row's identity everywhere else.
@DataClassName('CourseRow')
class Courses extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get profileId => integer().references(Profiles, #id)();
  TextColumn get courseId => text()();
  TextColumn get title => text()();
  TextColumn get raw => text()();
  IntColumn get importedAtMs => integer()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {profileId, courseId}
      ];
}

/// One retrieval item's SRS state. [stateJson] carries
/// reps/ease/intervalDays/dueEpochDay/lapses (see [encodeCardState]) so the
/// schema never couples to the scheduler's exact field set.
@DataClassName('CardRow')
class Cards extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get courseId => integer().references(Courses, #id)();
  TextColumn get itemId => text()();
  TextColumn get stateJson => text()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {courseId, itemId}
      ];
}

/// Append-only review log — a fold source (FSRS food, proposal-2 §6), never
/// mutated: [StudyDao] exposes append and read and nothing else. The card
/// row is merely the cached fold of this log through scheduleSm2.
@DataClassName('RevlogRow')
class Revlog extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get cardId => integer().references(Cards, #id)();
  TextColumn get grade => text()();
  IntColumn get tsMs => integer()();
  IntColumn get intervalBeforeDays => integer()();
  IntColumn get intervalAfterDays => integer()();
}

/// The household's optional parent PIN (P5): one row (id 0) holding the
/// per-household random salt and the salted SHA-256 digest — never the PIN
/// itself. It lives in the database rather than a platform keystore so the
/// same law holds on every surface, web included, and travels with the
/// household's data. There is deliberately no recovery column: a forgotten
/// PIN can only be cleared by clearing the app's data (the honest hard
/// path — a backdoor would make the gate a fiction).
@DataClassName('HouseholdPinRow')
class HouseholdPin extends Table {
  IntColumn get id => integer()();
  TextColumn get salt => text()();
  TextColumn get hash => text()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One checkpointed long-running task (proposal-2 §9): jobs_core's row plus
/// [payloadJson] — app-side context (which work, which whisper task) the
/// engine never reads. States travel as [jobs.JobState] names.
///
/// The Dart class is `JobsTable` (SQL name `jobs`) so the generated `jobs`
/// getter does not shadow the `jobs` import prefix inside the DAOs.
@DataClassName('JobRow')
class JobsTable extends Table {
  @override
  String get tableName => 'jobs';

  TextColumn get id => text()();
  TextColumn get kind => text()();
  TextColumn get state => text()();
  TextColumn get checkpoint => text().nullable()();
  IntColumn get totalUnits => integer()();
  IntColumn get doneUnits => integer()();
  IntColumn get createdAtMs => integer()();
  TextColumn get payloadJson => text().withDefault(const Constant('{}'))();

  @override
  Set<Column> get primaryKey => {id};
}

/// The stateJson codec for [Cards]. Kept next to the table so the column's
/// shape and its reader can never drift apart.
String encodeCardState(study.CardState s) => json.encode({
      'reps': s.reps,
      'ease': s.ease,
      'intervalDays': s.intervalDays,
      'dueEpochDay': s.dueEpochDay,
      'lapses': s.lapses,
    });

study.CardState decodeCardState(String itemId, String stateJson) {
  final m = json.decode(stateJson) as Map<String, dynamic>;
  return study.CardState(
    itemId: itemId,
    ease: (m['ease'] as num).toDouble(),
    intervalDays: m['intervalDays'] as int,
    dueEpochDay: m['dueEpochDay'] as int,
    reps: m['reps'] as int,
    lapses: m['lapses'] as int,
  );
}

@DriftAccessor(tables: [Courses, Cards, Revlog])
class StudyDao extends DatabaseAccessor<AppDatabase> with _$StudyDaoMixin {
  StudyDao(super.db);

  /// Validates [raw] with study_core's strict parser and stores it verbatim.
  /// Throws the parser's [FormatException] — with NOTHING written — on any
  /// malformed input (the parser law: never a half-import). Re-importing a
  /// course id this reader already has replaces the body and title but keeps
  /// the cards: learning history survives a revision. Returns the row id.
  Future<int> importCourse(
      {required int profileId, required String raw, required int nowMs}) async {
    final course = study.parseCourseString(raw); // throws before any write
    return transaction(() async {
      final existing = await (select(courses)
            ..where((c) =>
                c.profileId.equals(profileId) & c.courseId.equals(course.id)))
          .getSingleOrNull();
      if (existing != null) {
        await (update(courses)..where((c) => c.id.equals(existing.id))).write(
            CoursesCompanion(
                title: Value(course.title),
                raw: Value(raw),
                importedAtMs: Value(nowMs)));
        return existing.id;
      }
      return into(courses).insert(CoursesCompanion.insert(
          profileId: profileId,
          courseId: course.id,
          title: course.title,
          raw: raw,
          importedAtMs: nowMs));
    });
  }

  Future<List<CourseRow>> coursesOf(int profileId) => (select(courses)
        ..where((c) => c.profileId.equals(profileId))
        ..orderBy([(c) => OrderingTerm.asc(c.id)]))
      .get();

  /// itemId → SRS state for one course row (the donor CardRepository.load).
  Future<Map<String, study.CardState>> loadCardStates(int courseRowId) async {
    final rows = await (select(cards)
          ..where((c) => c.courseId.equals(courseRowId)))
        .get();
    return {
      for (final r in rows) r.itemId: decodeCardState(r.itemId, r.stateJson)
    };
  }

  /// One graded review, atomically: upsert the card's state to [after] and
  /// append one revlog row. [before] supplies the pre-review interval — the
  /// log entry the fold replays.
  Future<void> recordGrade(
      {required int courseRowId,
      required study.CardState before,
      required study.CardState after,
      required study.Grade grade,
      required int tsMs}) {
    assert(before.itemId == after.itemId, 'one review, one card');
    return transaction(() async {
      final existing = await (select(cards)
            ..where((c) =>
                c.courseId.equals(courseRowId) &
                c.itemId.equals(after.itemId)))
          .getSingleOrNull();
      final int cardId;
      if (existing != null) {
        cardId = existing.id;
        await (update(cards)..where((c) => c.id.equals(cardId))).write(
            CardsCompanion(stateJson: Value(encodeCardState(after))));
      } else {
        cardId = await into(cards).insert(CardsCompanion.insert(
            courseId: courseRowId,
            itemId: after.itemId,
            stateJson: encodeCardState(after)));
      }
      await into(revlog).insert(RevlogCompanion.insert(
          cardId: cardId,
          grade: grade.name,
          tsMs: tsMs,
          intervalBeforeDays: before.intervalDays,
          intervalAfterDays: after.intervalDays));
    });
  }

  /// The course's full review history, oldest first. Read-only by design.
  Future<List<RevlogRow>> revlogOf(int courseRowId) async {
    final q = select(revlog).join([
      innerJoin(cards, cards.id.equalsExp(revlog.cardId)),
    ])
      ..where(cards.courseId.equals(courseRowId))
      ..orderBy([OrderingTerm.asc(revlog.tsMs), OrderingTerm.asc(revlog.id)]);
    final rows = await q.get();
    return [for (final r in rows) r.readTable(revlog)];
  }
}

/// jobs_core's `JobStore` semantics over Drift. The engine's atomicity law
/// holds because [saveCheckpoint] is one transaction: read the row (refusing
/// to invent one), then merge exactly checkpoint + doneUnits. Everything
/// else here is app-side context the engine never touches.
///
/// The DAO cannot `implements jobs.JobStore` itself — Drift's inherited
/// `delete<T>(table)` collides with the contract's `delete(jobId)` — so
/// [store] hands the engine a thin adapter instead.
@DriftAccessor(tables: [JobsTable])
class JobsDao extends DatabaseAccessor<AppDatabase> with _$JobsDaoMixin {
  JobsDao(super.db);

  /// The engine-facing face of this DAO.
  late final jobs.JobStore store = _DriftJobStore(this);

  jobs.Job _toJob(JobRow r) => jobs.Job(
      id: r.id,
      kind: r.kind,
      state: jobs.JobState.values.byName(r.state),
      checkpoint: r.checkpoint,
      totalUnits: r.totalUnits,
      doneUnits: r.doneUnits,
      createdAtMs: r.createdAtMs);

  Future<jobs.Job?> load(String jobId) async {
    final r = await (select(jobsTable)..where((j) => j.id.equals(jobId)))
        .getSingleOrNull();
    return r == null ? null : _toJob(r);
  }

  Future<void> save(jobs.Job job) =>
      into(jobsTable).insertOnConflictUpdate(JobsTableCompanion.insert(
          id: job.id,
          kind: job.kind,
          state: job.state.name,
          checkpoint: Value(job.checkpoint),
          totalUnits: job.totalUnits,
          doneUnits: job.doneUnits,
          createdAtMs: job.createdAtMs));

  Future<void> saveCheckpoint(
          String jobId, String checkpoint, int doneUnits) =>
      transaction(() async {
        final r = await (select(jobsTable)..where((j) => j.id.equals(jobId)))
            .getSingleOrNull();
        if (r == null) {
          throw StateError('saveCheckpoint for unknown job "$jobId"');
        }
        await (update(jobsTable)..where((j) => j.id.equals(jobId))).write(
            JobsTableCompanion(
                checkpoint: Value(checkpoint), doneUnits: Value(doneUnits)));
      });

  Future<void> deleteJob(String jobId) =>
      (delete(jobsTable)..where((j) => j.id.equals(jobId))).go();

  Future<void> setPayload(String jobId, String payloadJson) =>
      (update(jobsTable)..where((j) => j.id.equals(jobId)))
          .write(JobsTableCompanion(payloadJson: Value(payloadJson)));

  Future<String> payloadOf(String jobId) async =>
      (await (select(jobsTable)..where((j) => j.id.equals(jobId)))
              .getSingle())
          .payloadJson;

  /// Once decode has revealed the window plan, the placeholder row learns
  /// its real unit count — before that, the runner would refuse the shape.
  Future<void> setTotalUnits(String jobId, int totalUnits) =>
      (update(jobsTable)..where((j) => j.id.equals(jobId)))
          .write(JobsTableCompanion(totalUnits: Value(totalUnits)));

  /// Every job that is not done — running (possibly orphaned by a kill),
  /// cancelled, failed. These are the resume cards the UI shows on reopen.
  Future<List<JobRow>> unfinished() => (select(jobsTable)
        ..where((j) => j.state.equals(jobs.JobState.done.name).not())
        ..orderBy([(j) => OrderingTerm.asc(j.createdAtMs)]))
      .get();
}

class _DriftJobStore implements jobs.JobStore {
  final JobsDao dao;
  _DriftJobStore(this.dao);

  @override
  Future<jobs.Job?> load(String jobId) => dao.load(jobId);

  @override
  Future<void> save(jobs.Job job) => dao.save(job);

  @override
  Future<void> saveCheckpoint(String jobId, String checkpoint, int doneUnits) =>
      dao.saveCheckpoint(jobId, checkpoint, doneUnits);

  @override
  Future<void> delete(String jobId) => dao.deleteJob(jobId);
}

@DriftAccessor(tables: [WordLedger])
class LedgerDao extends DatabaseAccessor<AppDatabase> with _$LedgerDaoMixin {
  LedgerDao(super.db);

  /// Adds [word] for [profileId], case-insensitively idempotent: a word the
  /// profile already keeps returns the existing row's id and writes nothing
  /// (the column's NOCASE collation makes the equality below fold case in
  /// SQLite itself). Returns the row id either way.
  Future<int> add(
          {required int profileId,
          required String word,
          String? lang,
          int? sourceWorkId,
          required int nowMs}) =>
      transaction(() async {
        final existing = await (select(wordLedger)
              ..where((w) =>
                  w.profileId.equals(profileId) & w.word.equals(word)))
            .getSingleOrNull();
        if (existing != null) return existing.id;
        return into(wordLedger).insert(WordLedgerCompanion.insert(
            profileId: profileId,
            word: word,
            lang: Value(lang),
            sourceWorkId: Value(sourceWorkId),
            addedAtMs: nowMs));
      });

  Future<void> remove(int id) =>
      (delete(wordLedger)..where((w) => w.id.equals(id))).go();

  /// One profile's ledger, newest first — the most recent catch on top.
  Future<List<WordLedgerRow>> wordsOf(int profileId) => (select(wordLedger)
        ..where((w) => w.profileId.equals(profileId))
        ..orderBy([
          (w) => OrderingTerm.desc(w.addedAtMs),
          (w) => OrderingTerm.desc(w.id)
        ]))
      .get();
}

@DriftAccessor(tables: [Profiles])
class ProfilesDao extends DatabaseAccessor<AppDatabase> with _$ProfilesDaoMixin {
  ProfilesDao(super.db);
  Future<int> create(String name) =>
      into(profiles).insert(ProfilesCompanion.insert(name: name));

  Future<List<Profile>> all() =>
      (select(profiles)..orderBy([(p) => OrderingTerm.asc(p.id)])).get();

  /// ADR-0006's settings escape: false (the honest default — see
  /// [Profiles.preferSystemVoice]) for a profile no row exists for yet.
  Future<bool> preferSystemVoice(int profileId) async {
    final row =
        await (select(profiles)..where((p) => p.id.equals(profileId)))
            .getSingleOrNull();
    return row?.preferSystemVoice ?? false;
  }

  Future<void> setPreferSystemVoice(int profileId, bool value) =>
      (update(profiles)..where((p) => p.id.equals(profileId)))
          .write(ProfilesCompanion(preferSystemVoice: Value(value)));
}

@DriftAccessor(
    tables: [Works, Segments, Layers, Alignments, Positions, Episodes,
        PlayerPositions])
class SpineDao extends DatabaseAccessor<AppDatabase> with _$SpineDaoMixin {
  SpineDao(super.db);

  Future<int> insertWork(
          {required int profileId,
          required String kind,
          required String title,
          required String persistence,
          required int firstSeenEpochDay,
          String? sourceUrl,
          String? lang}) =>
      into(works).insert(WorksCompanion.insert(
          profileId: profileId,
          kind: kind,
          title: title,
          persistence: persistence,
          firstSeenEpochDay: firstSeenEpochDay,
          sourceUrl: Value(sourceUrl),
          lang: Value(lang)));

  Future<void> insertSegments(
      int workId, List<({int idx, String kind, String text})> rows) =>
      batch((b) => b.insertAll(segments, [
            for (final r in rows)
              SegmentsCompanion.insert(
                  workId: workId, idx: r.idx, kind: r.kind, body: r.text)
          ]));

  Future<void> insertLayers(int workId,
          List<({int segmentIdx, String lang, String kind, String text})> rows) =>
      batch((b) => b.insertAll(layers, [
            for (final r in rows)
              LayersCompanion.insert(
                  workId: workId,
                  segmentIdx: r.segmentIdx,
                  lang: r.lang,
                  kind: r.kind,
                  body: r.text)
          ]));

  Future<List<Segment>> segmentsOf(int workId) =>
      (select(segments)
            ..where((s) => s.workId.equals(workId))
            ..orderBy([(s) => OrderingTerm.asc(s.idx)]))
          .get();

  Future<List<Layer>> layersOf(int workId, {required String lang}) =>
      (select(layers)
            ..where((l) => l.workId.equals(workId) & l.lang.equals(lang))
            ..orderBy([(l) => OrderingTerm.asc(l.segmentIdx)]))
          .get();

  /// The languages a work's layers of [kind] speak — what the reader's
  /// language toggle offers (ADR-0002: translations are per-segment layers).
  Future<List<String>> layerLangsOf(int workId, {required String kind}) async {
    final q = selectOnly(layers, distinct: true)
      ..addColumns([layers.lang])
      ..where(layers.workId.equals(workId) & layers.kind.equals(kind))
      ..orderBy([OrderingTerm.asc(layers.lang)]);
    final rows = await q.get();
    return [for (final r in rows) r.read(layers.lang)!];
  }

  Future<List<Work>> worksOf(int profileId) =>
      (select(works)..where((w) => w.profileId.equals(profileId))).get();

  /// Pin is a user's hand on the work (ADR-0002); callers promoting via pin
  /// pair this with [promoteWork].
  Future<void> setPinned(int workId, bool pinned) =>
      (update(works)..where((w) => w.id.equals(workId)))
          .write(WorksCompanion(pinned: Value(pinned)));

  /// Segment count without loading bodies — the library's progress
  /// denominator (position.segmentIdx / segmentCount).
  Future<int> segmentCount(int workId) async {
    final c = countAll();
    final q = selectOnly(segments)
      ..addColumns([c])
      ..where(segments.workId.equals(workId));
    return (await q.getSingle()).read(c) ?? 0;
  }

  /// One tiny row per (profile, work) — the donor's rewrite-the-book jank is
  /// structurally impossible (spine_db_test pins the row count).
  Future<void> savePosition(
          {required int profileId,
          required int workId,
          required int segmentIdx,
          required int wordIdx,
          required String lastModality}) =>
      into(positions).insertOnConflictUpdate(PositionsCompanion.insert(
          profileId: profileId,
          workId: workId,
          segmentIdx: segmentIdx,
          wordIdx: wordIdx,
          lastModality: lastModality,
          updatedAtMs: DateTime.now().millisecondsSinceEpoch));

  Future<Position?> position({required int profileId, required int workId}) =>
      (select(positions)
            ..where((p) =>
                p.profileId.equals(profileId) & p.workId.equals(workId)))
          .getSingleOrNull();

  Future<List<Position>> allPositions() => select(positions).get();

  Future<void> insertAlignments(int workId,
          List<({int segmentIdx, int tStartMs, int tEndMs})> rows) =>
      batch((b) => b.insertAll(alignments, [
            for (final r in rows)
              AlignmentsCompanion.insert(
                  workId: workId,
                  segmentIdx: r.segmentIdx,
                  tStartMs: r.tStartMs,
                  tEndMs: r.tEndMs)
          ]));

  Future<List<Alignment>> alignmentsOf(int workId) =>
      (select(alignments)
            ..where((a) => a.workId.equals(workId))
            ..orderBy([(a) => OrderingTerm.asc(a.tStartMs)]))
          .get();

  Future<void> promoteWork(int workId) =>
      (update(works)..where((w) => w.id.equals(workId)))
          .write(const WorksCompanion(persistence: Value('work')));

  /// Finishing is one of the user's promoting hands (ADR-0003 law 2);
  /// callers pair this with [promoteWork].
  Future<void> markFinished(int workId, int epochDay) =>
      (update(works)..where((w) => w.id.equals(workId)))
          .write(WorksCompanion(finishedEpochDay: Value(epochDay)));

  Future<void> deleteWork(int workId) => transaction(() async {
        await (delete(playerPositions)..where((p) => p.workId.equals(workId)))
            .go();
        await (delete(episodes)..where((e) => e.workId.equals(workId))).go();
        await (delete(positions)..where((p) => p.workId.equals(workId))).go();
        await (delete(alignments)..where((a) => a.workId.equals(workId))).go();
        await (delete(layers)..where((l) => l.workId.equals(workId))).go();
        await (delete(segments)..where((s) => s.workId.equals(workId))).go();
        await (delete(works)..where((w) => w.id.equals(workId))).go();
      });

  /// Executes the pure verdict from loom_core (ADR-0003 law 2). Returns the
  /// number of works removed.
  Future<int> sweepEphemera(
      {required int todayEpochDay, int retentionDays = 30}) async {
    final rows = await select(works).get();
    final verdict = core.sweepEphemera([
      for (final w in rows)
        core.Work(
            id: '${w.id}',
            kind: core.WorkKind.episode,
            persistence: w.persistence == 'work'
                ? core.Persistence.work
                : core.Persistence.ephemeron,
            firstSeenEpochDay: w.firstSeenEpochDay)
    ], todayEpochDay: todayEpochDay, retentionDays: retentionDays);
    for (final id in verdict) {
      await deleteWork(int.parse(id));
    }
    return verdict.length;
  }
}

/// A river row: the spine work plus its river metadata and feed title.
typedef RiverEntry = ({Work work, Episode episode, String feedTitle});

@DriftAccessor(tables: [Feeds, Episodes, Works, PlayerPositions])
class FeedsDao extends DatabaseAccessor<AppDatabase> with _$FeedsDaoMixin {
  FeedsDao(super.db);

  Future<int> insertFeed(
          {required int profileId,
          required String url,
          String title = '',
          bool autoDownload = false}) =>
      into(feeds).insert(FeedsCompanion.insert(
          profileId: profileId,
          url: url,
          title: Value(title),
          autoDownload: Value(autoDownload)));

  Future<List<Feed>> feedsOf(int profileId) => (select(feeds)
        ..where((f) => f.profileId.equals(profileId))
        ..orderBy([(f) => OrderingTerm.asc(f.id)]))
      .get();

  Future<Feed?> feedByUrl(int profileId, String url) => (select(feeds)
        ..where((f) => f.profileId.equals(profileId) & f.url.equals(url)))
      .getSingleOrNull();

  /// Persists the outcome of a refresh: adopted title, validators, and the
  /// breaker's serialized state. Null validators clear the column — the
  /// caller passes the state's current values, which already implement the
  /// donor's keep-old-when-absent law.
  Future<void> updateRefreshState(int feedId,
          {required String title,
          required String? etag,
          required String? lastModified,
          required String breakerJson}) =>
      (update(feeds)..where((f) => f.id.equals(feedId))).write(FeedsCompanion(
          title: Value(title),
          etag: Value(etag),
          lastModified: Value(lastModified),
          breakerJson: Value(breakerJson)));

  Future<void> setAutoDownload(int feedId, bool on) =>
      (update(feeds)..where((f) => f.id.equals(feedId)))
          .write(FeedsCompanion(autoDownload: Value(on)));

  Future<void> insertEpisode(
          {required int workId,
          required int feedId,
          required String guid,
          String? enclosureUrl,
          int? durationMs,
          required int publishedAtMs}) =>
      into(episodes).insert(EpisodesCompanion.insert(
          workId: Value(workId),
          feedId: feedId,
          guid: guid,
          enclosureUrl: Value(enclosureUrl),
          durationMs: Value(durationMs),
          publishedAtMs: publishedAtMs));

  Future<Episode?> episodeOf(int workId) =>
      (select(episodes)..where((e) => e.workId.equals(workId)))
          .getSingleOrNull();

  Future<Set<String>> guidsOf(int feedId) async {
    final q = selectOnly(episodes)
      ..addColumns([episodes.guid])
      ..where(episodes.feedId.equals(feedId));
    final rows = await q.get();
    return {for (final r in rows) r.read(episodes.guid)!};
  }

  /// THE river query — the fleet's one ordering code path (ADR-0003 law 1):
  /// reverse-chronological by publish time, nothing else, no other sort
  /// exists anywhere in the feature.
  Future<List<RiverEntry>> riverItems(int profileId) async {
    final q = select(episodes).join([
      innerJoin(works, works.id.equalsExp(episodes.workId)),
      innerJoin(feeds, feeds.id.equalsExp(episodes.feedId)),
    ])
      ..where(works.profileId.equals(profileId))
      ..orderBy([OrderingTerm.desc(episodes.publishedAtMs)]);
    final rows = await q.get();
    return [
      for (final r in rows)
        (
          work: r.readTable(works),
          episode: r.readTable(episodes),
          feedTitle: r.readTable(feeds).title,
        )
    ];
  }

  Future<void> markRead(int workId, int nowMs) =>
      (update(episodes)..where((e) => e.workId.equals(workId)))
          .write(EpisodesCompanion(readAtMs: Value(nowMs)));

  Future<void> setDuration(int workId, int durationMs) =>
      (update(episodes)..where((e) => e.workId.equals(workId)))
          .write(EpisodesCompanion(durationMs: Value(durationMs)));

  Future<void> savePlayerPosition(
          {required int profileId, required int workId, required int tMs}) =>
      into(playerPositions)
          .insertOnConflictUpdate(PlayerPositionsCompanion.insert(
              profileId: profileId,
              workId: workId,
              tMs: tMs,
              updatedAtMs: DateTime.now().millisecondsSinceEpoch));

  Future<PlayerPosition?> playerPosition(
          {required int profileId, required int workId}) =>
      (select(playerPositions)
            ..where((p) =>
                p.profileId.equals(profileId) & p.workId.equals(workId)))
          .getSingleOrNull();

  Future<List<PlayerPosition>> allPlayerPositions() =>
      select(playerPositions).get();

  /// Deleting a feed takes its unpromoted ephemera with it (ADR-0003 law 2);
  /// a promoted work belongs to the library now — only its river metadata
  /// goes (its sourceUrl still carries the enclosure).
  Future<void> deleteFeedCascade(int feedId) => transaction(() async {
        final rows = await (select(episodes)
              ..where((e) => e.feedId.equals(feedId)))
            .join([innerJoin(works, works.id.equalsExp(episodes.workId))])
            .get();
        for (final r in rows) {
          final work = r.readTable(works);
          if (work.persistence == 'ephemeron') {
            await db.spineDao.deleteWork(work.id);
          } else {
            await (delete(episodes)..where((e) => e.workId.equals(work.id)))
                .go();
          }
        }
        await (delete(feeds)..where((f) => f.id.equals(feedId))).go();
      });
}

/// One course's mastery line on the dashboard: how much of it is built.
typedef CourseMastery = ({String title, int mastered, int total});

/// The parent dashboard's per-profile LIFETIME BUILT view (P5). ADR-0003
/// law 5: additive totals of what exists — works kept, works finished,
/// cards mastered, listening reached, words collected. Every number comes
/// from tables the features already write; the dashboard adds no
/// bookkeeping of its own and nothing here can express a streak.
typedef LifetimeBuilt = ({
  int worksKept,
  int worksFinished,
  int cardsMastered,
  int wordsCollected,
  int listeningMs,
  CourseMastery? currentCourse,
});

/// The household layer over the per-profile app: the parent-PIN row, profile
/// rename/delete (the PIN-gated operations), and the dashboard stats.
@DriftAccessor(tables: [HouseholdPin, Profiles, Works, Positions,
    PlayerPositions, Alignments, Feeds, Courses, Cards, Revlog, WordLedger])
class HouseholdDao extends DatabaseAccessor<AppDatabase>
    with _$HouseholdDaoMixin {
  HouseholdDao(super.db);

  static const _pinRowId = 0;

  Future<HouseholdPinRow?> readPin() =>
      (select(householdPin)..where((p) => p.id.equals(_pinRowId)))
          .getSingleOrNull();

  /// Upserts THE pin row — set and change are the same write; the
  /// current-PIN-required law lives in ParentPinService, not here.
  Future<void> writePin({required String salt, required String hash}) =>
      into(householdPin).insertOnConflictUpdate(HouseholdPinCompanion.insert(
          id: Value(_pinRowId), salt: salt, hash: hash));

  Future<void> clearPin() =>
      (delete(householdPin)..where((p) => p.id.equals(_pinRowId))).go();

  Future<void> renameProfile(int profileId, String name) =>
      (update(profiles)..where((p) => p.id.equals(profileId)))
          .write(ProfilesCompanion(name: Value(name)));

  /// Removes a reader and every trace of their data, atomically. Order
  /// matters: feeds first (deleteFeedCascade takes river metadata and
  /// unpromoted ephemera), then every remaining work (positions, player
  /// positions, alignments, layers, segments ride along in deleteWork),
  /// then courses with their cards and revlog, then the word ledger, then
  /// the profile row itself.
  Future<void> deleteProfileCascade(int profileId) => transaction(() async {
        for (final f in await db.feedsDao.feedsOf(profileId)) {
          await db.feedsDao.deleteFeedCascade(f.id);
        }
        for (final w in await db.spineDao.worksOf(profileId)) {
          await db.spineDao.deleteWork(w.id);
        }
        for (final c in await db.studyDao.coursesOf(profileId)) {
          final cardRows = await (select(cards)
                ..where((x) => x.courseId.equals(c.id)))
              .get();
          for (final card in cardRows) {
            await (delete(revlog)..where((r) => r.cardId.equals(card.id)))
                .go();
          }
          await (delete(cards)..where((x) => x.courseId.equals(c.id))).go();
          await (delete(courses)..where((x) => x.id.equals(c.id))).go();
        }
        await (delete(wordLedger)..where((w) => w.profileId.equals(profileId)))
            .go();
        await (delete(profiles)..where((p) => p.id.equals(profileId))).go();
      });

  /// The dashboard query: what this reader has built, from existing tables
  /// only. "Mastered" is study_core's own threshold (interval has reached
  /// [masteryIntervalDays]); the current course is the most recent import.
  Future<LifetimeBuilt> lifetimeBuiltOf(int profileId,
      {int masteryIntervalDays = 7}) async {
    final workRows = await db.spineDao.worksOf(profileId);
    final worksKept = workRows.where((w) => w.persistence == 'work').length;
    final worksFinished =
        workRows.where((w) => w.finishedEpochDay != null).length;

    final wc = countAll();
    final wq = selectOnly(wordLedger)
      ..addColumns([wc])
      ..where(wordLedger.profileId.equals(profileId));
    final wordsCollected = (await wq.getSingle()).read(wc) ?? 0;

    final courseRows = await db.studyDao.coursesOf(profileId);
    CourseRow? latest;
    for (final c in courseRows) {
      if (latest == null ||
          c.importedAtMs > latest.importedAtMs ||
          (c.importedAtMs == latest.importedAtMs && c.id > latest.id)) {
        latest = c;
      }
    }
    var cardsMastered = 0;
    CourseMastery? currentCourse;
    for (final c in courseRows) {
      final states = await db.studyDao.loadCardStates(c.id);
      final mastered = states.values
          .where((s) => s.intervalDays >= masteryIntervalDays)
          .length;
      cardsMastered += mastered;
      if (identical(c, latest)) {
        int total;
        try {
          // Import validated this text; parse for the item count so
          // never-reviewed items still count toward the whole.
          final course = study.parseCourseString(c.raw);
          total = course.nodes.fold(0, (a, n) => a + n.items.length);
        } on FormatException {
          total = states.length; // a row that no longer parses degrades
        }
        currentCourse = (title: c.title, mastered: mastered, total: total);
      }
    }

    // Listening reached: per work the MAX of the raw player position and
    // the aligned listen-position's segment end, summed across works — max,
    // never sum, because a stale raw row survives the transcript that
    // superseded it (the cursor law moves writes to Positions).
    final reached = <int, int>{};
    final rawRows = await (select(playerPositions)
          ..where((p) => p.profileId.equals(profileId)))
        .get();
    for (final r in rawRows) {
      reached[r.workId] = r.tMs;
    }
    final aligned = await (select(positions).join([
      innerJoin(
          alignments,
          alignments.workId.equalsExp(positions.workId) &
              alignments.segmentIdx.equalsExp(positions.segmentIdx)),
    ])
          ..where(positions.profileId.equals(profileId) &
              positions.lastModality.equals('listen')))
        .get();
    for (final r in aligned) {
      final workId = r.readTable(positions).workId;
      final end = r.readTable(alignments).tEndMs;
      if (end > (reached[workId] ?? 0)) reached[workId] = end;
    }
    final listeningMs = reached.values.fold(0, (a, b) => a + b);

    return (
      worksKept: worksKept,
      worksFinished: worksFinished,
      cardsMastered: cardsMastered,
      wordsCollected: wordsCollected,
      listeningMs: listeningMs,
      currentCourse: currentCourse,
    );
  }
}

@DriftDatabase(
    tables: [Profiles, Works, Segments, Layers, Alignments, Positions, Feeds,
        Episodes, PlayerPositions, Courses, Cards, Revlog, JobsTable,
        WordLedger, HouseholdPin],
    daos: [ProfilesDao, SpineDao, FeedsDao, StudyDao, JobsDao, LedgerDao,
        HouseholdDao])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);
  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 7;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            // P2: feeds + river metadata + the no-alignments player fallback.
            await m.createTable(feeds);
            await m.createTable(episodes);
            await m.createTable(playerPositions);
          }
          if (from < 3) {
            // Study slice: imported courses, card SRS state, and the
            // append-only revlog.
            await m.createTable(courses);
            await m.createTable(cards);
            await m.createTable(revlog);
          }
          if (from < 4) {
            // P3: checkpointed transcription jobs.
            await m.createTable(jobsTable);
          }
          if (from < 5) {
            // The word ledger (per-profile, NOCASE-deduped, SET NULL
            // provenance — see [WordLedger]).
            await m.createTable(wordLedger);
          }
          if (from < 6) {
            // P5 household layer: the optional parent-PIN row (salt +
            // salted-SHA-256 digest — see [HouseholdPin]).
            await m.createTable(householdPin);
          }
          if (from < 7) {
            // ADR-0006's settings escape (see [Profiles.preferSystemVoice]).
            await m.addColumn(profiles, profiles.preferSystemVoice);
          }
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );
}
