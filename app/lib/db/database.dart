import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:jobs_core/jobs_core.dart' as jobs;
import 'package:loom_core/loom_core.dart' as core;
import 'package:study_core/study_core.dart' as study;

import '../features/reader/reader_prefs.dart';

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

  /// The study crown's per-profile scheduler choice: 'classic' (SM-2, the
  /// default) or 'fsrs' (beta, opt-in). A string, not a bool, so a third
  /// option never needs a schema change — same escape-hatch shape as
  /// [preferSystemVoice].
  TextColumn get scheduler => text().withDefault(const Constant('classic'))();

  /// The Up Next queue's finish law (P4 mercy #3): finishing an episode
  /// removes it from the queue by default (false); true keeps it in place
  /// instead — the AntennaPod top-2 request was having a CHOICE here.
  BoolColumn get keepFinishedInQueue =>
      boolean().withDefault(const Constant(false))();

  /// The offline DSP preprocess's (Campaign 6, ADR-0012) app-wide default:
  /// false (the honest default — processing is opt-in) unless a feed's
  /// own [Feeds.dspEnabled] overrides it. Same escape-hatch shape as
  /// [preferSystemVoice]/[keepFinishedInQueue] — a household setting, not
  /// a per-feed one.
  BoolColumn get dspGlobalDefault =>
      boolean().withDefault(const Constant(false))();

  /// Campaign 4's one schema hop (v18): the `ReaderPrefs` blob — the print
  /// reader's typography — as JSON in one column, the same shape
  /// [Cards.stateJson] already uses, rather than a column per field. `'{}'`
  /// decodes to all-default prefs (see [ReaderPrefs.decode]). Phase 2's
  /// Parafoveal toggle/sigma and follow-along are session-scoped instead
  /// (the reader's existing wpm precedent: "holds for the session," not
  /// persisted) — they don't live here. [ReadingDays], not this column, is
  /// where Phase 5's lifetime totals read from.
  TextColumn get readerPrefsJson =>
      text().withDefault(const Constant('{}'))();
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

  /// The scroll-mode translation-layer toggle (ADR-0008 "Babel" Phase 3):
  /// persisted per work, off by default, same shape as [pinned]. Only
  /// meaningful — and only offered in the reader's UI — when
  /// [TranslationSentences] rows actually exist for this work.
  BoolColumn get showTranslationLayer =>
      boolean().withDefault(const Constant(false))();

  /// Campaign 8 "Babel widens" Phase 1: WHICH language
  /// [showTranslationLayer] refers to — `null` means no language has
  /// ever been chosen (the show-toggle carries no meaning without one).
  /// The two columns are kept in sync by the DAO's own setters
  /// ([SpineDao.setActiveTranslationLang]/[SpineDao
  /// .clearActiveTranslationLang]), never written independently — "one
  /// active translation layer per work at a time" is the law this column
  /// makes literal: there is exactly one slot, not a set.
  TextColumn get activeTranslationLang => text().nullable()();
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

/// Sentence-indexed Spanish (or a future language) translations (ADR-0008
/// "Babel", Phase 3) — one row per (work, segment, sentence WITHIN that
/// segment), keyed by the RAW index `core.splitSentences(segment.text)`
/// assigns that sentence, never a position in some already-filtered list
/// (`sentenceUnitsOf` in the translation feature is the one place this
/// numbering is decided — the job that writes these rows and the reader
/// that reads them both call it, so they can't drift apart). Finer-grained
/// than [Layers], whose primary key stops at segmentIdx: whisper's X->EN
/// translate task (a [Layers] row, kind `'mt'`) produces one string per
/// WHOLE segment; Marian translates one sentence at a time, and the speak
/// loop's per-sentence substitution needs that granularity to pair a
/// Spanish sentence with the English cursor it plays under — the karaoke
/// pairing IS the cursor law, no separate sync mechanism.
///
/// [sourceText] is the ENGLISH sentence this row translated AT WRITE TIME —
/// compared against the current segment's sentence at lookup, so a
/// re-ingest that reshapes a work's segments makes a stale row read as
/// "missing" (falls back to English) instead of confidently speaking or
/// displaying a translation for a sentence that no longer exists there.
class TranslationSentences extends Table {
  IntColumn get workId => integer().references(Works, #id)();
  IntColumn get segmentIdx => integer()();
  IntColumn get sentenceIdx => integer()();
  TextColumn get lang => text()();
  TextColumn get sourceText => text()();
  TextColumn get body => text()();

  /// Campaign 8 "Babel widens" Phase 5: which engine produced this row —
  /// `'marian'` or a Brain identifier (`domovoi:stove`,
  /// `domovoi:byok:<provider>`, ...). Provenance only — nothing reads
  /// this to decide behavior, only to display it, so a `null` row
  /// (every row written before this column existed) is read as
  /// `'marian'` by convention rather than migrated: every row in this
  /// table predates the Brain lane, so it IS a Marian row.
  TextColumn get engine => text().nullable()();

  @override
  Set<Column> get primaryKey => {workId, segmentIdx, sentenceIdx, lang};
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

/// Campaign 4 Phase 5's "additive lifetime total" (ADR-0003 law 5: no
/// streaks) — one row per profile per UTC epoch day the reader's cursor
/// actually advanced. [Positions] cannot answer "how many distinct days
/// have you read" on its own: it is one overwritten row per (profile,
/// work), so a work re-opened daily for a month still shows one
/// `updatedAtMs`. This table is the append-only, idempotent (dupes
/// collapse via the composite key + `insertOrIgnore`) record that makes a
/// lifetime reading-days COUNT honestly computable — never a current/
/// longest streak, which the law forbids outright. Landed in the same v18
/// hop as [Profiles.readerPrefsJson] because a schema hop is spent once.
/// The write side ([ProfilesDao.recordReadingDay]) landed ahead of Phase
/// 5's own UI, deliberately: the totals screen should read a table that
/// already has real rows in it, not an empty one on the day it ships.
class ReadingDays extends Table {
  IntColumn get profileId => integer().references(Profiles, #id)();
  IntColumn get epochDay => integer()();
  @override
  Set<Column> get primaryKey => {profileId, epochDay};
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

  /// The archive-page URL comms_core's parser found on the last successful
  /// refresh (RFC 5005 rel="next"/rel="prev-archive") — null for the
  /// overwhelmingly common case of a host that publishes no archive.
  /// Re-derived fresh on every successful parse; untouched otherwise.
  TextColumn get nextPageUrl => text().nullable()();

  /// Per-podcast playback settings (P4 mercy #2). Null always defers to
  /// the player's global default — nothing here is a fallback the player
  /// invents on its own.
  ///
  /// The player's speed for episodes of this feed; null uses the global
  /// speed the player already cycles through.
  RealColumn get speedOverride => real().nullable()();

  /// Seconds to auto-seek past when an episode starts from position 0;
  /// null skips the seek. Never applied on a resume (only a fresh start).
  IntColumn get skipIntroSeconds => integer().nullable()();

  /// Seconds before an episode's real end to stop/advance at; null plays
  /// to the true end.
  IntColumn get skipOutroSeconds => integer().nullable()();

  /// Audio eviction (P4 "archive, never forget"): keep only the N
  /// most-recently-published episodes' downloaded audio for this feed on
  /// disk; null keeps all of it. The episode ROWS are never touched by
  /// this — only the audio file, via [Episodes.archivedAtMs].
  IntColumn get keepLatestAudio => integer().nullable()();

  /// This feed's rules (Campaign 5 Phase 3), a JSON-encoded ordered list —
  /// the house pattern (see [breakerJson]) rather than a new table, since
  /// a rule set is small and lives entirely with its feed. Evaluated at
  /// ingest, before an item ever becomes a river row; see
  /// `feed_rules.dart`. `'[]'` (no rules) is the default — every existing
  /// feed keeps behaving exactly as it did before this column existed.
  TextColumn get rulesJson => text().withDefault(const Constant('[]'))();

  /// The offline DSP preprocess's (Campaign 6, ADR-0012) per-feed opt-in:
  /// null defers to [Profiles.dspGlobalDefault] — same "nothing here is a
  /// fallback the player invents on its own" law as [speedOverride] and
  /// its siblings above. true/false is an explicit override either way.
  BoolColumn get dspEnabled => boolean().nullable()();

  /// Channel-level artwork (Campaign 9 Phase 5, "the river gets faces"):
  /// the REMOTE image URL comms_core's parser found (itunes:image href,
  /// falling back to RSS's own image/url) — null when the host publishes
  /// neither. This column exists only to detect "did the artwork change"
  /// across refreshes; the actual downloaded file lives at a path derived
  /// from the feed id (`DeviceServices.artworkFileFor`), fetched once and
  /// never re-fetched at render.
  TextColumn get imageUrl => text().nullable()();
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

  /// When this episode's downloaded audio FILE was evicted to reclaim
  /// storage (P4 "archive, never forget") — null means the audio, if it
  /// was ever downloaded, is still on disk (or never was). The row itself
  /// is NEVER deleted by eviction; only [deleteWork] and the ephemera
  /// sweep (ADR-0003's own, unrelated, age-based law) remove a row.
  IntColumn get archivedAtMs => integer().nullable()();

  /// Cross-feed dedup (Campaign 5 Phase 3): why this episode is hidden
  /// from the river — `'url'` (canonical URLs matched after tracker
  /// stripping) or `'title'` (exact-normalized titles within 48h). Null
  /// means not suppressed — the overwhelming common case. Dedup NEVER
  /// suppresses two items from the SAME feed (reposts are the author's
  /// choice); see `feed_dedup.dart`. The row is never deleted — "hidden",
  /// not "gone".
  TextColumn get dedupReason => text().nullable()();

  /// The OTHER episode's workId this one was judged a duplicate of (the
  /// older/canonical side of the pair) — null when [dedupReason] is null.
  /// Exists so that if the canonical work is later deleted ([deleteWork],
  /// the ephemera sweep, unfollowing its feed), this row's suppression can
  /// be cleared rather than left hidden with nothing left pointing at why
  /// — "hidden" must never quietly become "lost".
  IntColumn get duplicateOfWorkId =>
      integer().nullable().references(Works, #id)();

  /// The downloaded file's duration BEFORE the offline DSP preprocess ran
  /// (Campaign 6, ADR-0012) — measured off the actual audio, not the
  /// feed's own (sometimes wrong) declared [durationMs]. Null until a DSP
  /// pass has actually run for this episode.
  IntColumn get dspOriginalDurationMs => integer().nullable()();

  /// The processed file's duration AFTER the same preprocess — the
  /// lifetime "time saved" counter sums (dspOriginalDurationMs -
  /// dspProcessedDurationMs) across every episode where both are set.
  /// Null exactly when [dspOriginalDurationMs] is null (set together, in
  /// the same atomic promote — never one without the other).
  IntColumn get dspProcessedDurationMs => integer().nullable()();

  @override
  Set<Column> get primaryKey => {workId};
}

/// The Up Next queue (P4 mercy #3): a position-ordered, per-profile list
/// of works waiting to play next. Named `QueueTable`/`queue` rather than
/// `Queue` for the same reason [JobsTable] isn't `Jobs` — `Queue` collides
/// with `dart:collection`.
@DataClassName('QueueRow')
class QueueTable extends Table {
  @override
  String get tableName => 'queue';

  IntColumn get id => integer().autoIncrement()();
  IntColumn get profileId => integer().references(Profiles, #id)();
  IntColumn get workId => integer().references(Works, #id)();

  /// Ascending = play order; the DAO renumbers on every insert/remove/
  /// reorder so positions stay contiguous from 0 rather than accreting
  /// gaps.
  IntColumn get position => integer()();
  IntColumn get addedAtMs => integer()();
}

/// A saved library filter (Campaign 5 Phase 2): a name plus a
/// [LibraryQuery] frozen to JSON — the house pattern (Cards.stateJson,
/// Feeds.breakerJson) rather than a second persistence mechanism; this
/// repo has no SharedPreferences usage anywhere. [position] orders the
/// chips row the same way [QueueTable.position] orders play order — the
/// DAO renumbers contiguously from 0 on every insert/remove/reorder.
@DataClassName('SavedViewRow')
class SavedViews extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get profileId => integer().references(Profiles, #id)();
  TextColumn get name => text()();
  TextColumn get queryJson => text()();
  IntColumn get position => integer()();
  IntColumn get createdAtMs => integer()();
}

/// The study crown, Phase 2: a captured moment during playback — episode,
/// position, when it was taken. [segmentIdx] is the sentence it snapped to,
/// via the SAME alignments the karaoke view and the read<->listen handoff
/// project through (Snipd's known complaint is wrong clip boundaries from a
/// raw ±15s guess; sentence-snapped-or-honestly-unbound is the bar here).
/// Null means the work had no transcript yet when this was taken —
/// [CapturesDao.backfillForWork] binds it once one arrives; a capture is
/// never dropped for lacking one.
@DataClassName('CaptureRow')
class Captures extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get profileId => integer().references(Profiles, #id)();
  IntColumn get workId => integer().references(Works, #id)();
  IntColumn get positionMs => integer()();
  IntColumn get createdAtMs => integer()();
  IntColumn get segmentIdx => integer().nullable()();

  /// Campaign 7 (ADR-0013): which file of a multi-file audiobook
  /// [positionMs] is relative to. Null for every capture on a
  /// single-file work (an episode, or a one-file audiobook) — there
  /// [positionMs] alone is already unambiguous, so null means "not
  /// applicable", never "unknown".
  IntColumn get fileIdx => integer().nullable()();
}

/// The study crown, Phase 1: zero-effort resurfacing for extracts/vocab —
/// the gentle two-button on-ramp, never a replacement for the four-grade
/// course flow. Keyed by (profileId, sourceType, sourceId) rather than a
/// foreign key to any one table, because a review item can come from either
/// [WordLedger] ('ledger') or [Captures] ('capture') — this table is
/// deliberately the only thing that knows both exist. [stateJson] carries
/// the SAME shape [encodeCardState]/[decodeCardState] already read/write
/// for course cards (ease/intervalDays/dueEpochDay/reps/lapses); a row is
/// created lazily on first grade, exactly like [Cards] — an ungraded
/// source has no row and is treated as a brand-new, immediately-due card.
@DataClassName('DailyReviewCardRow')
class DailyReviewCards extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get profileId => integer().references(Profiles, #id)();
  TextColumn get sourceType => text()();
  IntColumn get sourceId => integer()();
  TextColumn get stateJson => text()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {profileId, sourceType, sourceId},
  ];
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

  /// Campaign 7 (ADR-0013): which file of a multi-file audiobook this
  /// position belongs to. A single-file work (every episode; a one-file
  /// audiobook) is always file 0, which is also this column's default —
  /// no pre-campaign row ever needed to change, and no episode-reading
  /// code ever needs to look at it.
  IntColumn get fileIdx => integer().withDefault(const Constant(0))();
  @override
  Set<Column> get primaryKey => {profileId, workId};
}

/// Campaign 7 (ADR-0013 "audiobooks are a door"): one settings row per
/// audiobook work, created once at import time. Deliberately its OWN
/// table rather than an extension of [Feeds]'s playback columns — an
/// audiobook has no feed to hang a row off of, and generalizing
/// [Feeds.speedOverride] to "any audio source" would mean touching every
/// site that already reads it as feed-scoped. See the ADR for the full
/// reasoning.
@DataClassName('AudiobookRow')
class Audiobooks extends Table {
  IntColumn get workId => integer().references(Works, #id)();

  /// Per-book speed override, the audiobook parallel to
  /// [Feeds.speedOverride]. Null defers to the player's own global speed
  /// cycling — the same "nothing here is a fallback the player invents on
  /// its own" law every other per-source override in this schema follows.
  RealColumn get speedOverride => real().nullable()();

  @override
  Set<Column> get primaryKey => {workId};
}

/// Campaign 7: one row per file in an audiobook, in PLAYBACK order.
/// [fileIdx] is the file axis of the position law (ADR-0013): a Position
/// for a multi-file work is (fileIdx, offset) rather than one cross-file
/// millisecond, because a later file's duration is only ever learned once
/// it actually plays (nothing probes it at import) — there is no sound
/// way to collapse "file 2, 30s in" to a single number without knowing
/// how long files 0 and 1 run.
@DataClassName('AudiobookFileRow')
class AudiobookFiles extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get workId => integer().references(Works, #id)();
  IntColumn get fileIdx => integer()();

  /// Absolute path to the copied file inside app storage — the
  /// referenced-vs-copied verdict (ADR-0013) is "copied, always" on this
  /// app's one shipped native tier, so this is never a path the app
  /// doesn't own.
  TextColumn get path => text()();

  /// Learned lazily the first time this file actually plays
  /// ([PlayerController]'s duration-stream handler) — null until then.
  /// Nothing at import time probes this; the library tile's progress is
  /// file-count-coarse, not time-precise, so nothing needs it sooner.
  IntColumn get durationMs => integer().nullable()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {workId, fileIdx},
  ];
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
  IntColumn get sourceWorkId => integer().nullable().references(
    Works,
    #id,
    onDelete: KeyAction.setNull,
  )();
  IntColumn get addedAtMs => integer()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {profileId, word},
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
    {profileId, courseId},
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
    {courseId, itemId},
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

/// The study crown: FSRS's additive half of the same [Cards.stateJson] blob,
/// under an `fsrs`-prefixed key family so it can never collide with the
/// classic keys above. Missing or corrupt FSRS keys decode as
/// [study.FsrsCardState.initial] — "corrupt/missing -> treated as new" is
/// the law the spec asks for, and unlike [decodeCardState] this never
/// throws, so callers don't need a separate skip-path for it.
study.FsrsCardState decodeFsrsCardState(
  String itemId,
  String stateJson,
  int todayEpochDay,
) {
  try {
    final m = json.decode(stateJson);
    if (m is! Map<String, dynamic> ||
        m['fsrsStability'] == null ||
        m['fsrsDifficulty'] == null) {
      return study.FsrsCardState.initial(itemId, todayEpochDay);
    }
    return study.FsrsCardState(
      itemId: itemId,
      stability: (m['fsrsStability'] as num).toDouble(),
      difficulty: (m['fsrsDifficulty'] as num).toDouble(),
      dueEpochDay: m['fsrsDueEpochDay'] as int,
      reps: m['fsrsReps'] as int? ?? 0,
      lapses: m['fsrsLapses'] as int? ?? 0,
      lastReviewEpochDay: m['fsrsLastReviewEpochDay'] as int?,
    );
  } catch (_) {
    return study.FsrsCardState.initial(itemId, todayEpochDay);
  }
}

Map<String, dynamic> _fsrsBlobKeys(study.FsrsCardState f) => {
  'fsrsStability': f.stability,
  'fsrsDifficulty': f.difficulty,
  'fsrsDueEpochDay': f.dueEpochDay,
  'fsrsReps': f.reps,
  'fsrsLapses': f.lapses,
  if (f.lastReviewEpochDay != null)
    'fsrsLastReviewEpochDay': f.lastReviewEpochDay,
};

Map<String, dynamic> _classicBlobKeys(study.CardState s) => {
  'reps': s.reps,
  'ease': s.ease,
  'intervalDays': s.intervalDays,
  'dueEpochDay': s.dueEpochDay,
  'lapses': s.lapses,
};

/// Merges a [classic] and/or [fsrs] update into [existingStateJson]'s blob,
/// leaving whichever half is not supplied exactly as it was. This is the
/// mechanism behind the lossy-switch-back law (ADR-0009): grading under one
/// scheduler must never move, recompute, or erase the other's stored
/// progress — it must simply not be there yet, or be there untouched. A
/// corrupt existing blob is treated as empty rather than thrown (a single
/// bad row must not block the review that would have fixed it).
String mergeCardStateJson(
  String? existingStateJson, {
  study.CardState? classic,
  study.FsrsCardState? fsrs,
}) {
  var merged = <String, dynamic>{};
  if (existingStateJson != null) {
    try {
      final decoded = json.decode(existingStateJson);
      if (decoded is Map<String, dynamic>) merged = Map.of(decoded);
    } catch (_) {
      // Corrupt existing blob: this grade starts it fresh rather than
      // failing the review that would otherwise repair it.
    }
  }
  if (classic != null) merged.addAll(_classicBlobKeys(classic));
  if (fsrs != null) merged.addAll(_fsrsBlobKeys(fsrs));
  return json.encode(merged);
}

@DriftAccessor(tables: [Courses, Cards, Revlog])
class StudyDao extends DatabaseAccessor<AppDatabase> with _$StudyDaoMixin {
  StudyDao(super.db);

  /// Validates [raw] with study_core's strict parser and stores it verbatim.
  /// Throws the parser's [FormatException] — with NOTHING written — on any
  /// malformed input (the parser law: never a half-import). Re-importing a
  /// course id this reader already has replaces the body and title but keeps
  /// the cards: learning history survives a revision. Returns the row id.
  Future<int> importCourse({
    required int profileId,
    required String raw,
    required int nowMs,
  }) async {
    final course = study.parseCourseString(raw); // throws before any write
    return transaction(() async {
      final existing =
          await (select(courses)..where(
                (c) =>
                    c.profileId.equals(profileId) &
                    c.courseId.equals(course.id),
              ))
              .getSingleOrNull();
      if (existing != null) {
        await (update(courses)..where((c) => c.id.equals(existing.id))).write(
          CoursesCompanion(
            title: Value(course.title),
            raw: Value(raw),
            importedAtMs: Value(nowMs),
          ),
        );
        return existing.id;
      }
      return into(courses).insert(
        CoursesCompanion.insert(
          profileId: profileId,
          courseId: course.id,
          title: course.title,
          raw: raw,
          importedAtMs: nowMs,
        ),
      );
    });
  }

  Future<List<CourseRow>> coursesOf(int profileId) =>
      (select(courses)
            ..where((c) => c.profileId.equals(profileId))
            ..orderBy([(c) => OrderingTerm.asc(c.id)]))
          .get();

  /// itemId → SRS state for one course row (the donor CardRepository.load).
  /// A row whose blob fails to decode is skipped individually — the store's
  /// law (see backup_core's TrellisImporter precedent) — rather than
  /// throwing for the whole course.
  Future<Map<String, study.CardState>> loadCardStates(int courseRowId) async {
    final rows = await (select(
      cards,
    )..where((c) => c.courseId.equals(courseRowId))).get();
    final out = <String, study.CardState>{};
    for (final r in rows) {
      try {
        out[r.itemId] = decodeCardState(r.itemId, r.stateJson);
      } catch (_) {
        // Malformed entry: skip it, not the course.
      }
    }
    return out;
  }

  /// itemId → FSRS state for one course row, at [todayEpochDay] (needed only
  /// to seed [study.FsrsCardState.initial] for a card FSRS has never touched
  /// — see [decodeFsrsCardState]). Never throws or skips: missing/corrupt
  /// FSRS data always degrades to "new", per the additive-JSON law.
  Future<Map<String, study.FsrsCardState>> loadFsrsCardStates(
    int courseRowId,
    int todayEpochDay,
  ) async {
    final rows = await (select(
      cards,
    )..where((c) => c.courseId.equals(courseRowId))).get();
    return {
      for (final r in rows)
        r.itemId: decodeFsrsCardState(r.itemId, r.stateJson, todayEpochDay),
    };
  }

  /// The FSRS state to grade FROM for [itemId]: the card's existing FSRS
  /// half if one is already stored, or a lazy seed from [classicBefore] via
  /// [study.seedFsrsFromClassic] if FSRS has never touched this card yet.
  ///
  /// Seeding happens HERE, lazily, at the moment a card is about to be
  /// graded under FSRS for the first time — not in bulk when a profile
  /// flips its scheduler setting. This mirrors the lazy-creation law
  /// [Cards] rows already follow (created on first grade, not on course
  /// import): a profile can own courses with hundreds of never-reviewed
  /// items, and switch-time seeding would write FSRS state for every one
  /// of them whether or not FSRS ever grades them. [classicBefore] should
  /// be whatever classic state the card currently has (or
  /// `CardState.initial(...)` for an item never graded under either
  /// scheduler) — seeding from a genuinely-fresh classic state is safe:
  /// `scheduleFsrs`'s first-review branch (`reps == 0`) computes S0/D0
  /// from the grade alone and never reads the seed's stability/difficulty,
  /// so a fresh item still starts FSRS fresh.
  Future<study.FsrsCardState> fsrsStateToGradeFrom({
    required int courseRowId,
    required String itemId,
    required study.CardState classicBefore,
    required int todayEpochDay,
  }) async {
    final row =
        await (select(cards)..where(
              (c) => c.courseId.equals(courseRowId) & c.itemId.equals(itemId),
            ))
            .getSingleOrNull();
    if (row != null) {
      try {
        final decoded = json.decode(row.stateJson);
        if (decoded is Map<String, dynamic> &&
            decoded['fsrsStability'] != null &&
            decoded['fsrsDifficulty'] != null) {
          // A real, decodable FSRS row already exists — trust it. Decoded
          // by hand (not via decodeFsrsCardState) so a corrupt value here
          // falls through to seeding below instead of that function's own
          // "corrupt -> initial()" default, which would discard real
          // classic history this function can recover from instead.
          return study.FsrsCardState(
            itemId: itemId,
            stability: (decoded['fsrsStability'] as num).toDouble(),
            difficulty: (decoded['fsrsDifficulty'] as num).toDouble(),
            dueEpochDay: decoded['fsrsDueEpochDay'] as int,
            reps: decoded['fsrsReps'] as int? ?? 0,
            lapses: decoded['fsrsLapses'] as int? ?? 0,
            lastReviewEpochDay: decoded['fsrsLastReviewEpochDay'] as int?,
          );
        }
      } catch (_) {
        // Corrupt blob: fall through to seeding.
      }
    }
    return study.seedFsrsFromClassic(classicBefore, todayEpochDay);
  }

  /// One graded review, atomically: upsert the card's state to [after] and
  /// append one revlog row. [before] supplies the pre-review interval — the
  /// log entry the fold replays.
  Future<void> recordGrade({
    required int courseRowId,
    required study.CardState before,
    required study.CardState after,
    required study.Grade grade,
    required int tsMs,
  }) {
    assert(before.itemId == after.itemId, 'one review, one card');
    return transaction(() async {
      final existing =
          await (select(cards)..where(
                (c) =>
                    c.courseId.equals(courseRowId) &
                    c.itemId.equals(after.itemId),
              ))
              .getSingleOrNull();
      final int cardId;
      if (existing != null) {
        cardId = existing.id;
        final merged = mergeCardStateJson(existing.stateJson, classic: after);
        await (update(cards)..where((c) => c.id.equals(cardId))).write(
          CardsCompanion(stateJson: Value(merged)),
        );
      } else {
        cardId = await into(cards).insert(
          CardsCompanion.insert(
            courseId: courseRowId,
            itemId: after.itemId,
            stateJson: mergeCardStateJson(null, classic: after),
          ),
        );
      }
      await into(revlog).insert(
        RevlogCompanion.insert(
          cardId: cardId,
          grade: grade.name,
          tsMs: tsMs,
          intervalBeforeDays: before.intervalDays,
          intervalAfterDays: after.intervalDays,
        ),
      );
    });
  }

  /// The FSRS twin of [recordGrade]: same atomic upsert-then-append shape,
  /// but writes only the `fsrs`-prefixed half of the blob (via
  /// [mergeCardStateJson]), leaving any classic half exactly as it was —
  /// the lossy-switch-back law depends on this.
  Future<void> recordGradeFsrs({
    required int courseRowId,
    required study.FsrsCardState before,
    required study.FsrsCardState after,
    required study.Grade grade,
    required int tsMs,
  }) {
    assert(before.itemId == after.itemId, 'one review, one card');
    return transaction(() async {
      final existing =
          await (select(cards)..where(
                (c) =>
                    c.courseId.equals(courseRowId) &
                    c.itemId.equals(after.itemId),
              ))
              .getSingleOrNull();
      final int cardId;
      if (existing != null) {
        cardId = existing.id;
        final merged = mergeCardStateJson(existing.stateJson, fsrs: after);
        await (update(cards)..where((c) => c.id.equals(cardId))).write(
          CardsCompanion(stateJson: Value(merged)),
        );
      } else {
        cardId = await into(cards).insert(
          CardsCompanion.insert(
            courseId: courseRowId,
            itemId: after.itemId,
            stateJson: mergeCardStateJson(null, fsrs: after),
          ),
        );
      }
      final beforeInterval =
          before.dueEpochDay -
          (before.lastReviewEpochDay ?? before.dueEpochDay);
      await into(revlog).insert(
        RevlogCompanion.insert(
          cardId: cardId,
          grade: grade.name,
          tsMs: tsMs,
          intervalBeforeDays: beforeInterval < 0 ? 0 : beforeInterval,
          intervalAfterDays:
              after.dueEpochDay -
              (after.lastReviewEpochDay ?? after.dueEpochDay),
        ),
      );
    });
  }

  /// The course's full review history, oldest first. Read-only by design.
  Future<List<RevlogRow>> revlogOf(int courseRowId) async {
    final q =
        select(
            revlog,
          ).join([innerJoin(cards, cards.id.equalsExp(revlog.cardId))])
          ..where(cards.courseId.equals(courseRowId))
          ..orderBy([
            OrderingTerm.asc(revlog.tsMs),
            OrderingTerm.asc(revlog.id),
          ]);
    final rows = await q.get();
    return [for (final r in rows) r.readTable(revlog)];
  }

  /// Campaign 4 Phase 5's Echo tile: every grade this profile has ever
  /// made, across every course — [revlogOf] scoped to one course row,
  /// this scoped to a whole profile via the Revlog -> Cards -> Courses
  /// chain (Revlog itself carries no profileId).
  Future<int> totalReviewsOf(int profileId) async {
    final c = countAll();
    final q = selectOnly(revlog).join([
      innerJoin(cards, cards.id.equalsExp(revlog.cardId)),
      innerJoin(courses, courses.id.equalsExp(cards.courseId)),
    ])
      ..addColumns([c])
      ..where(courses.profileId.equals(profileId));
    return (await q.getSingle()).read(c) ?? 0;
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
    createdAtMs: r.createdAtMs,
  );

  Future<jobs.Job?> load(String jobId) async {
    final r = await (select(
      jobsTable,
    )..where((j) => j.id.equals(jobId))).getSingleOrNull();
    return r == null ? null : _toJob(r);
  }

  Future<void> save(jobs.Job job) => into(jobsTable).insertOnConflictUpdate(
    JobsTableCompanion.insert(
      id: job.id,
      kind: job.kind,
      state: job.state.name,
      checkpoint: Value(job.checkpoint),
      totalUnits: job.totalUnits,
      doneUnits: job.doneUnits,
      createdAtMs: job.createdAtMs,
    ),
  );

  Future<void> saveCheckpoint(String jobId, String checkpoint, int doneUnits) =>
      transaction(() async {
        final r = await (select(
          jobsTable,
        )..where((j) => j.id.equals(jobId))).getSingleOrNull();
        if (r == null) {
          throw StateError('saveCheckpoint for unknown job "$jobId"');
        }
        await (update(jobsTable)..where((j) => j.id.equals(jobId))).write(
          JobsTableCompanion(
            checkpoint: Value(checkpoint),
            doneUnits: Value(doneUnits),
          ),
        );
      });

  Future<void> deleteJob(String jobId) =>
      (delete(jobsTable)..where((j) => j.id.equals(jobId))).go();

  Future<void> setPayload(String jobId, String payloadJson) =>
      (update(jobsTable)..where((j) => j.id.equals(jobId))).write(
        JobsTableCompanion(payloadJson: Value(payloadJson)),
      );

  Future<String> payloadOf(String jobId) async => (await (select(
    jobsTable,
  )..where((j) => j.id.equals(jobId))).getSingle()).payloadJson;

  /// Once decode has revealed the window plan, the placeholder row learns
  /// its real unit count — before that, the runner would refuse the shape.
  Future<void> setTotalUnits(String jobId, int totalUnits) =>
      (update(jobsTable)..where((j) => j.id.equals(jobId))).write(
        JobsTableCompanion(totalUnits: Value(totalUnits)),
      );

  /// Every job that is not done — running (possibly orphaned by a kill),
  /// cancelled, failed. These are the resume cards the UI shows on reopen.
  Future<List<JobRow>> unfinished() =>
      (select(jobsTable)
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
  Future<int> add({
    required int profileId,
    required String word,
    String? lang,
    int? sourceWorkId,
    required int nowMs,
  }) => transaction(() async {
    final existing =
        await (select(wordLedger)..where(
              (w) => w.profileId.equals(profileId) & w.word.equals(word),
            ))
            .getSingleOrNull();
    if (existing != null) return existing.id;
    return into(wordLedger).insert(
      WordLedgerCompanion.insert(
        profileId: profileId,
        word: word,
        lang: Value(lang),
        sourceWorkId: Value(sourceWorkId),
        addedAtMs: nowMs,
      ),
    );
  });

  Future<void> remove(int id) =>
      (delete(wordLedger)..where((w) => w.id.equals(id))).go();

  /// One profile's ledger, newest first — the most recent catch on top.
  Future<List<WordLedgerRow>> wordsOf(int profileId) =>
      (select(wordLedger)
            ..where((w) => w.profileId.equals(profileId))
            ..orderBy([
              (w) => OrderingTerm.desc(w.addedAtMs),
              (w) => OrderingTerm.desc(w.id),
            ]))
          .get();
}

@DriftAccessor(tables: [Profiles, ReadingDays])
class ProfilesDao extends DatabaseAccessor<AppDatabase>
    with _$ProfilesDaoMixin {
  ProfilesDao(super.db);
  Future<int> create(String name) =>
      into(profiles).insert(ProfilesCompanion.insert(name: name));

  Future<List<Profile>> all() =>
      (select(profiles)..orderBy([(p) => OrderingTerm.asc(p.id)])).get();

  /// ADR-0006's settings escape: false (the honest default — see
  /// [Profiles.preferSystemVoice]) for a profile no row exists for yet.
  Future<bool> preferSystemVoice(int profileId) async {
    final row = await (select(
      profiles,
    )..where((p) => p.id.equals(profileId))).getSingleOrNull();
    return row?.preferSystemVoice ?? false;
  }

  Future<void> setPreferSystemVoice(int profileId, bool value) =>
      (update(profiles)..where((p) => p.id.equals(profileId))).write(
        ProfilesCompanion(preferSystemVoice: Value(value)),
      );

  /// 'classic' (the honest default — see [Profiles.scheduler]) for a
  /// profile no row exists for yet.
  Future<String> scheduler(int profileId) async {
    final row = await (select(
      profiles,
    )..where((p) => p.id.equals(profileId))).getSingleOrNull();
    return row?.scheduler ?? 'classic';
  }

  Future<void> setScheduler(int profileId, String value) =>
      (update(profiles)..where((p) => p.id.equals(profileId))).write(
        ProfilesCompanion(scheduler: Value(value)),
      );

  /// The Up Next queue's finish law (P4 mercy #3): false — matching
  /// [Profiles.keepFinishedInQueue]'s own default — for a profile no row
  /// exists for yet.
  Future<bool> keepFinishedInQueue(int profileId) async {
    final row = await (select(
      profiles,
    )..where((p) => p.id.equals(profileId))).getSingleOrNull();
    return row?.keepFinishedInQueue ?? false;
  }

  Future<void> setKeepFinishedInQueue(int profileId, bool value) =>
      (update(profiles)..where((p) => p.id.equals(profileId))).write(
        ProfilesCompanion(keepFinishedInQueue: Value(value)),
      );

  /// The offline DSP preprocess's (Campaign 6, ADR-0012) household default:
  /// false — matching [Profiles.dspGlobalDefault]'s own default — for a
  /// profile no row exists for yet.
  Future<bool> dspGlobalDefault(int profileId) async {
    final row = await (select(
      profiles,
    )..where((p) => p.id.equals(profileId))).getSingleOrNull();
    return row?.dspGlobalDefault ?? false;
  }

  Future<void> setDspGlobalDefault(int profileId, bool value) =>
      (update(profiles)..where((p) => p.id.equals(profileId))).write(
        ProfilesCompanion(dspGlobalDefault: Value(value)),
      );

  /// The Campaign-4 prefs blob (see [Profiles.readerPrefsJson]) — all
  /// defaults for a profile no row exists for yet.
  Future<ReaderPrefs> readerPrefs(int profileId) async {
    final row = await (select(profiles)..where((p) => p.id.equals(profileId)))
        .getSingleOrNull();
    return ReaderPrefs.decode(row?.readerPrefsJson ?? '{}');
  }

  Future<void> setReaderPrefs(int profileId, ReaderPrefs prefs) =>
      (update(profiles)..where((p) => p.id.equals(profileId)))
          .write(ProfilesCompanion(readerPrefsJson: Value(prefs.encode())));

  /// Campaign 9 Phase 2 ("resume after restart"): records [workId] as the
  /// most recently played work, in the SAME shared blob [readerPrefs]
  /// already owns — a read-modify-write so whatever else lives in the
  /// blob (typography today) rides along untouched, the same law
  /// [ReaderPrefs.copyWith] itself enforces.
  Future<void> recordLastPlayed(int profileId, int workId) async {
    final prefs = await readerPrefs(profileId);
    await setReaderPrefs(profileId, prefs.copyWith(lastPlayedWorkId: workId));
  }

  /// Campaign 4 Phase 5's write side (see [ReadingDays]'s own doc comment
  /// for why this table exists at all): idempotent by the composite
  /// (profileId, epochDay) primary key, so a work reopened many times in
  /// one UTC day still records that day exactly once. `insertOrIgnore`
  /// over an upsert on purpose — there is nothing on the row worth
  /// overwriting once it exists.
  Future<void> recordReadingDay(int profileId, int epochDay) => into(
          readingDays)
      .insert(
          ReadingDaysCompanion.insert(profileId: profileId, epochDay: epochDay),
          mode: InsertMode.insertOrIgnore);
}

@DriftAccessor(
    tables: [Works, Segments, Layers, Alignments, Positions, Episodes,
        PlayerPositions, Captures, QueueTable, TranslationSentences,
        Audiobooks, AudiobookFiles])
class SpineDao extends DatabaseAccessor<AppDatabase> with _$SpineDaoMixin {
  SpineDao(super.db);

  Future<int> insertWork({
    required int profileId,
    required String kind,
    required String title,
    required String persistence,
    required int firstSeenEpochDay,
    String? sourceUrl,
    String? lang,
  }) => into(works).insert(
    WorksCompanion.insert(
      profileId: profileId,
      kind: kind,
      title: title,
      persistence: persistence,
      firstSeenEpochDay: firstSeenEpochDay,
      sourceUrl: Value(sourceUrl),
      lang: Value(lang),
    ),
  );

  Future<void> insertSegments(
    int workId,
    List<({int idx, String kind, String text})> rows,
  ) => batch(
    (b) => b.insertAll(segments, [
      for (final r in rows)
        SegmentsCompanion.insert(
          workId: workId,
          idx: r.idx,
          kind: r.kind,
          body: r.text,
        ),
    ]),
  );

  Future<void> insertLayers(
    int workId,
    List<({int segmentIdx, String lang, String kind, String text})> rows,
  ) => batch(
    (b) => b.insertAll(layers, [
      for (final r in rows)
        LayersCompanion.insert(
          workId: workId,
          segmentIdx: r.segmentIdx,
          lang: r.lang,
          kind: r.kind,
          body: r.text,
        ),
    ]),
  );

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

  Future<Work?> workById(int id) =>
      (select(works)..where((w) => w.id.equals(id))).getSingleOrNull();

  /// Pin is a user's hand on the work (ADR-0002); callers promoting via pin
  /// pair this with [promoteWork].
  Future<void> setPinned(int workId, bool pinned) =>
      (update(works)..where((w) => w.id.equals(workId))).write(
        WorksCompanion(pinned: Value(pinned)),
      );

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
  Future<void> savePosition({
    required int profileId,
    required int workId,
    required int segmentIdx,
    required int wordIdx,
    required String lastModality,
  }) => into(positions).insertOnConflictUpdate(
    PositionsCompanion.insert(
      profileId: profileId,
      workId: workId,
      segmentIdx: segmentIdx,
      wordIdx: wordIdx,
      lastModality: lastModality,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    ),
  );

  Future<Position?> position({required int profileId, required int workId}) =>
      (select(positions)..where(
            (p) => p.profileId.equals(profileId) & p.workId.equals(workId),
          ))
          .getSingleOrNull();

  Future<List<Position>> allPositions() => select(positions).get();

  Future<void> insertAlignments(
    int workId,
    List<({int segmentIdx, int tStartMs, int tEndMs})> rows,
  ) => batch(
    (b) => b.insertAll(alignments, [
      for (final r in rows)
        AlignmentsCompanion.insert(
          workId: workId,
          segmentIdx: r.segmentIdx,
          tStartMs: r.tStartMs,
          tEndMs: r.tEndMs,
        ),
    ]),
  );

  Future<List<Alignment>> alignmentsOf(int workId) =>
      (select(alignments)
            ..where((a) => a.workId.equals(workId))
            ..orderBy([(a) => OrderingTerm.asc(a.tStartMs)]))
          .get();

  Future<void> promoteWork(int workId) =>
      (update(works)..where((w) => w.id.equals(workId))).write(
        const WorksCompanion(persistence: Value('work')),
      );

  /// Undo's restore path for [promoteWork] (Campaign 5's Keep is undoable):
  /// writes persistence back to whatever it was, verbatim — a work already
  /// promoted before the Keep must stay promoted after Undo, not get
  /// demoted.
  Future<void> setPersistence(int workId, String persistence) =>
      (update(works)..where((w) => w.id.equals(workId)))
          .write(WorksCompanion(persistence: Value(persistence)));

  /// Finishing is one of the user's promoting hands (ADR-0003 law 2);
  /// callers pair this with [promoteWork].
  Future<void> markFinished(int workId, int epochDay) =>
      (update(works)..where((w) => w.id.equals(workId))).write(
        WorksCompanion(finishedEpochDay: Value(epochDay)),
      );

  Future<void> deleteWork(int workId) => transaction(() async {
        // The Up Next queue (P4 mercy #3) references works by id under
        // `PRAGMA foreign_keys = ON` — without this line, sweeping a
        // queued ephemeron or unfollowing its feed throws a foreign-key
        // violation instead of quietly taking the row with it.
        await (delete(queueTable)..where((q) => q.workId.equals(workId)))
            .go();
        await (delete(playerPositions)..where((p) => p.workId.equals(workId)))
            .go();
        await (delete(captures)..where((c) => c.workId.equals(workId))).go();
        // Children before the parent audiobooks row — AudiobookFiles rows
        // carry the DB record of the copied files; the actual bytes on disk
        // are the caller's job (ADR-0013), mirroring how deleteWork has
        // never touched a downloaded episode's audio file either.
        await (delete(audiobookFiles)..where((f) => f.workId.equals(workId)))
            .go();
        await (delete(audiobooks)..where((a) => a.workId.equals(workId))).go();
        // Cross-feed dedup (Campaign 5 Phase 3): if anything was
        // suppressed as a duplicate of the work about to be deleted,
        // un-suppress it first — a canonical row can vanish (unfollow,
        // ephemera sweep) without taking its duplicate's visibility with
        // it. "Hidden" must never quietly become "lost".
        await (update(episodes)
              ..where((e) => e.duplicateOfWorkId.equals(workId)))
            .write(const EpisodesCompanion(
                dedupReason: Value(null), duplicateOfWorkId: Value(null)));
        await (delete(episodes)..where((e) => e.workId.equals(workId))).go();
        await (delete(positions)..where((p) => p.workId.equals(workId))).go();
        await (delete(alignments)..where((a) => a.workId.equals(workId))).go();
        await (delete(translationSentences)
              ..where((t) => t.workId.equals(workId)))
            .go();
        await (delete(layers)..where((l) => l.workId.equals(workId))).go();
        await (delete(segments)..where((s) => s.workId.equals(workId))).go();
        await (delete(works)..where((w) => w.id.equals(workId))).go();
      });

  // ───── translation layers (ADR-0008 "Babel" Phase 3) ─────

  /// Whether the scroll-mode dual display is on for this work. False (the
  /// honest default — see [Works.showTranslationLayer]) for a work no row
  /// exists for yet.
  Future<bool> showTranslationLayer(int workId) async {
    final row = await (select(works)..where((w) => w.id.equals(workId)))
        .getSingleOrNull();
    return row?.showTranslationLayer ?? false;
  }

  Future<void> setShowTranslationLayer(int workId, bool value) =>
      (update(works)..where((w) => w.id.equals(workId)))
          .write(WorksCompanion(showTranslationLayer: Value(value)));

  /// The one active translation target language for this work (Campaign
  /// 8 "Babel widens" Phase 1) — `null` for a work no row exists for yet
  /// or that has never had one chosen. See [Works.activeTranslationLang].
  Future<String?> activeTranslationLang(int workId) async {
    final row = await (select(works)..where((w) => w.id.equals(workId)))
        .getSingleOrNull();
    return row?.activeTranslationLang;
  }

  /// Sets the one active translation target — replacing whatever was
  /// active before, never adding a second ("one active translation layer
  /// per work at a time"). Keeps the legacy [Works.showTranslationLayer]
  /// bool in sync (turned on) so nothing that still reads it alone sees
  /// a stale `false` while a language is actually active.
  Future<void> setActiveTranslationLang(int workId, String lang) =>
      (update(works)..where((w) => w.id.equals(workId))).write(
          WorksCompanion(
              activeTranslationLang: Value(lang),
              showTranslationLayer: const Value(true)));

  /// Clears the active slot — same sync law as [setActiveTranslationLang],
  /// in reverse.
  Future<void> clearActiveTranslationLang(int workId) =>
      (update(works)..where((w) => w.id.equals(workId))).write(
          const WorksCompanion(
              activeTranslationLang: Value(null),
              showTranslationLayer: Value(false)));

  /// Sets a work's declared source language (Campaign 8 "Babel widens"
  /// Phase 1's calm per-work selector — see [Works.lang]). Most intake
  /// paths never populate this at import time; a reader who knows better
  /// corrects it here. No auto-detection — recorded ceiling.
  Future<void> setWorkLang(int workId, String lang) =>
      (update(works)..where((w) => w.id.equals(workId)))
          .write(WorksCompanion(lang: Value(lang)));

  /// Persists one translated sentence — idempotent by (workId, segmentIdx,
  /// sentenceIdx, lang): re-running a unit (a retry, or a resumed job
  /// re-executing the same unit) overwrites with the same inputs rather
  /// than duplicating a row.
  Future<void> upsertTranslationSentence({
    required int workId,
    required int segmentIdx,
    required int sentenceIdx,
    required String lang,
    required String sourceText,
    required String body,
    String? engine,
  }) =>
      into(translationSentences).insertOnConflictUpdate(
          TranslationSentencesCompanion.insert(
              workId: workId,
              segmentIdx: segmentIdx,
              sentenceIdx: sentenceIdx,
              lang: lang,
              sourceText: sourceText,
              body: body,
              engine: Value(engine)));

  /// Every translated sentence a work has in [lang], keyed by
  /// (segmentIdx, sentenceIdx) — the shape the scroll-mode dual display and
  /// the speak loop's substitution both look sentences up through.
  Future<Map<(int, int), TranslationSentence>> translationSentencesOf(
      int workId,
      {required String lang}) async {
    final rows = await (select(translationSentences)
          ..where(
              (t) => t.workId.equals(workId) & t.lang.equals(lang)))
        .get();
    return {
      for (final r in rows) (r.segmentIdx, r.sentenceIdx): r,
    };
  }

  /// Whether this work has ANY translated sentences in [lang] yet — the
  /// reader's honesty gate for showing the dual-display toggle at all (a
  /// work no translation job has ever touched offers nothing to switch on).
  Future<bool> hasTranslationSentences(int workId, {required String lang}) async {
    final c = countAll();
    final q = selectOnly(translationSentences)
      ..addColumns([c])
      ..where(translationSentences.workId.equals(workId) &
          translationSentences.lang.equals(lang));
    return ((await q.getSingle()).read(c) ?? 0) > 0;
  }

  /// Executes the pure verdict from loom_core (ADR-0003 law 2). Returns the
  /// number of works removed.
  Future<int> sweepEphemera({
    required int todayEpochDay,
    int retentionDays = 30,
  }) async {
    final rows = await select(works).get();
    final verdict = core.sweepEphemera(
      [
        for (final w in rows)
          core.Work(
            id: '${w.id}',
            kind: core.WorkKind.episode,
            persistence: w.persistence == 'work'
                ? core.Persistence.work
                : core.Persistence.ephemeron,
            firstSeenEpochDay: w.firstSeenEpochDay,
          ),
      ],
      todayEpochDay: todayEpochDay,
      retentionDays: retentionDays,
    );
    for (final id in verdict) {
      await deleteWork(int.parse(id));
    }
    return verdict.length;
  }
}

/// The study crown, Phase 2: captures made during playback. Sentence-snap
/// binding lives here, over the SAME [core.Spine] projection everything
/// else in this file uses (positionAtAudioTime) — never a raw ±15s guess.
@DriftAccessor(tables: [Captures, Alignments])
class CapturesDao extends DatabaseAccessor<AppDatabase>
    with _$CapturesDaoMixin {
  CapturesDao(super.db);

  Future<core.Spine> _spineOf(int workId) async {
    final rows = await (select(
      alignments,
    )..where((a) => a.workId.equals(workId))).get();
    return core.Spine(
      segments: const [],
      layers: const [],
      alignments: [
        for (final a in rows)
          core.Alignment(
            segmentIdx: a.segmentIdx,
            tStartMs: a.tStartMs,
            tEndMs: a.tEndMs,
          ),
      ],
    );
  }

  /// Saves a capture at [positionMs]. When [workId] already has alignments
  /// (a transcript exists), binds the sentence containing that position
  /// immediately; otherwise [segmentIdx] stays null — [backfillForWork]
  /// binds it once transcription completes. Never a fabricated window.
  ///
  /// [fileIdx] (Campaign 7, ADR-0013) names which file of a multi-file
  /// audiobook [positionMs] is relative to; null (every pre-campaign
  /// caller) for a single-file work, where [positionMs] alone is already
  /// unambiguous.
  Future<int> capture({
    required int profileId,
    required int workId,
    required int positionMs,
    required int nowMs,
    int? fileIdx,
  }) async {
    final spine = await _spineOf(workId);
    final segmentIdx = spine.alignments.isEmpty
        ? null
        : spine.positionAtAudioTime(positionMs).segmentIdx;
    return into(captures).insert(
      CapturesCompanion.insert(
        profileId: profileId,
        workId: workId,
        positionMs: positionMs,
        createdAtMs: nowMs,
        segmentIdx: Value(segmentIdx),
        fileIdx: Value(fileIdx),
      ),
    );
  }

  /// Binds every still-unbound capture on [workId] — called alongside
  /// [PlayerController.reloadAlignments] when a transcription job
  /// completes. A no-op (not a throw) if the work still has no alignments.
  /// Returns how many captures were bound.
  Future<int> backfillForWork(int workId) async {
    final spine = await _spineOf(workId);
    if (spine.alignments.isEmpty) return 0;
    final unbound = await (select(
      captures,
    )..where((c) => c.workId.equals(workId) & c.segmentIdx.isNull())).get();
    for (final c in unbound) {
      final segmentIdx = spine.positionAtAudioTime(c.positionMs).segmentIdx;
      await (update(captures)..where((t) => t.id.equals(c.id))).write(
        CapturesCompanion(segmentIdx: Value(segmentIdx)),
      );
    }
    return unbound.length;
  }

  Future<List<CaptureRow>> capturesOf(int workId) =>
      (select(captures)
            ..where((c) => c.workId.equals(workId))
            ..orderBy([(c) => OrderingTerm.asc(c.positionMs)]))
          .get();

  /// Every capture belonging to any work this profile owns — the study
  /// crown's daily review queue reads across the whole profile, not one
  /// episode at a time.
  Future<List<CaptureRow>> capturesOfProfile(int profileId) async {
    final rows = await (select(captures).join([
      innerJoin(works, works.id.equalsExp(captures.workId)),
    ])..where(works.profileId.equals(profileId))).get();
    return [for (final r in rows) r.readTable(captures)];
  }
}

/// The study crown, Phase 1: daily review's DAO. See [DailyReviewCards]'s
/// doc comment for why this is keyed by (sourceType, sourceId) rather than
/// two foreign keys.
@DriftAccessor(tables: [DailyReviewCards, WordLedger, Captures, Works])
class DailyReviewDao extends DatabaseAccessor<AppDatabase>
    with _$DailyReviewDaoMixin {
  DailyReviewDao(super.db);

  String _itemId(String sourceType, int sourceId) => '$sourceType:$sourceId';

  /// One source's current state, or a brand-new (immediately due) one if
  /// it has never been graded — the same lazy-creation law [Cards] rows
  /// follow.
  Future<study.CardState> stateOf({
    required int profileId,
    required String sourceType,
    required int sourceId,
    required int todayEpochDay,
  }) async {
    final row =
        await (select(dailyReviewCards)..where(
              (c) =>
                  c.profileId.equals(profileId) &
                  c.sourceType.equals(sourceType) &
                  c.sourceId.equals(sourceId),
            ))
            .getSingleOrNull();
    final itemId = _itemId(sourceType, sourceId);
    return row == null
        ? study.CardState.initial(
            itemId,
            const study.SrsDefaults(),
            todayEpochDay,
          )
        : decodeCardState(itemId, row.stateJson);
  }

  Future<void> recordGrade({
    required int profileId,
    required String sourceType,
    required int sourceId,
    required study.CardState after,
  }) {
    return transaction(() async {
      final existing =
          await (select(dailyReviewCards)..where(
                (c) =>
                    c.profileId.equals(profileId) &
                    c.sourceType.equals(sourceType) &
                    c.sourceId.equals(sourceId),
              ))
              .getSingleOrNull();
      final stateJson = encodeCardState(after);
      if (existing != null) {
        await (update(dailyReviewCards)..where((c) => c.id.equals(existing.id)))
            .write(DailyReviewCardsCompanion(stateJson: Value(stateJson)));
      } else {
        await into(dailyReviewCards).insert(
          DailyReviewCardsCompanion.insert(
            profileId: profileId,
            sourceType: sourceType,
            sourceId: sourceId,
            stateJson: stateJson,
          ),
        );
      }
    });
  }

  /// itemId ("type:id") -> state, for every ledger word and capture this
  /// profile owns — course items never enter this map; it is never built
  /// from [Cards]. A malformed row is skipped individually (the store's
  /// law, matching [StudyDao.loadCardStates]'s hardening) rather than
  /// failing the whole queue.
  Future<Map<String, study.CardState>> loadAll(
    int profileId,
    int todayEpochDay,
  ) async {
    final words = await (select(
      wordLedger,
    )..where((w) => w.profileId.equals(profileId))).get();
    final captureRows = await _capturesOfProfile(profileId);
    final existing = await (select(
      dailyReviewCards,
    )..where((c) => c.profileId.equals(profileId))).get();
    final byKey = {
      for (final r in existing) _itemId(r.sourceType, r.sourceId): r,
    };

    final out = <String, study.CardState>{};
    void addSource(String sourceType, int sourceId) {
      final itemId = _itemId(sourceType, sourceId);
      final row = byKey[itemId];
      try {
        out[itemId] = row == null
            ? study.CardState.initial(
                itemId,
                const study.SrsDefaults(),
                todayEpochDay,
              )
            : decodeCardState(itemId, row.stateJson);
      } catch (_) {
        // Malformed entry: skip it, not the queue.
      }
    }

    for (final w in words) {
      addSource('ledger', w.id);
    }
    for (final c in captureRows) {
      addSource('capture', c.id);
    }
    return out;
  }

  /// How many extracts/vocab are due right now — the home surface's quiet
  /// chip, separate from any course's due count.
  Future<int> dueCount(int profileId, int todayEpochDay) async {
    final all = await loadAll(profileId, todayEpochDay);
    return all.values.where((s) => s.isDue(todayEpochDay)).length;
  }

  // Reuses CapturesDao's own join rather than duplicating it; DailyReviewDao
  // cannot call another DAO's instance methods directly (DatabaseAccessor
  // exposes tables, not sibling DAOs), so this repeats the same join inline.
  Future<List<CaptureRow>> _capturesOfProfile(int profileId) async {
    final rows = await (select(captures).join([
      innerJoin(works, works.id.equalsExp(captures.workId)),
    ])..where(works.profileId.equals(profileId))).get();
    return [for (final r in rows) r.readTable(captures)];
  }
}

/// A queue row plus the work it names — the queue view's list without a
/// second query per row.
typedef QueueEntry = ({QueueRow row, Work work});

/// The Up Next queue (P4 mercy #3): a position-ordered, per-profile list of
/// works waiting to play next. Positions stay contiguous from 0 — every
/// mutating method renumbers rather than leaving gaps, so "the head" is
/// always simply the row at position 0.
@DriftAccessor(tables: [QueueTable, Works])
class QueueDao extends DatabaseAccessor<AppDatabase> with _$QueueDaoMixin {
  QueueDao(super.db);

  /// The queue in play order — index 0 is the head.
  Future<List<QueueRow>> queueOf(int profileId) =>
      (select(queueTable)
            ..where((q) => q.profileId.equals(profileId))
            ..orderBy([(q) => OrderingTerm.asc(q.position)]))
          .get();

  Future<QueueRow?> headOf(int profileId) async {
    final rows = await queueOf(profileId);
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<QueueEntry>> queueEntriesOf(int profileId) async {
    final q =
        select(
            queueTable,
          ).join([innerJoin(works, works.id.equalsExp(queueTable.workId))])
          ..where(queueTable.profileId.equals(profileId))
          ..orderBy([OrderingTerm.asc(queueTable.position)]);
    final rows = await q.get();
    return [
      for (final r in rows)
        (row: r.readTable(queueTable), work: r.readTable(works)),
    ];
  }

  /// Queues [workId] right after whatever's currently playing. Already
  /// queued moves it to the head instead of duplicating.
  Future<void> playNext({
    required int profileId,
    required int workId,
    required int nowMs,
  }) => _insertAt(
    profileId: profileId,
    workId: workId,
    nowMs: nowMs,
    atHead: true,
  );

  /// Appends [workId] to the tail. Already queued moves it to the tail
  /// instead of duplicating.
  Future<void> playLast({
    required int profileId,
    required int workId,
    required int nowMs,
  }) => _insertAt(
    profileId: profileId,
    workId: workId,
    nowMs: nowMs,
    atHead: false,
  );

  Future<void> _insertAt({
    required int profileId,
    required int workId,
    required int nowMs,
    required bool atHead,
  }) => transaction(() async {
    await (delete(queueTable)..where(
          (q) => q.profileId.equals(profileId) & q.workId.equals(workId),
        ))
        .go();
    final rest = await queueOf(profileId);
    if (atHead) {
      for (final r in rest) {
        await (update(queueTable)..where((q) => q.id.equals(r.id))).write(
          QueueTableCompanion(position: Value(r.position + 1)),
        );
      }
    }
    await into(queueTable).insert(
      QueueTableCompanion.insert(
        profileId: profileId,
        workId: workId,
        position: atHead ? 0 : rest.length,
        addedAtMs: nowMs,
      ),
    );
  });

  /// Drops [workId] from the queue (a no-op if it isn't there) and
  /// renumbers what remains contiguously.
  Future<void> remove({required int profileId, required int workId}) =>
      transaction(() async {
        await (delete(queueTable)..where(
              (q) => q.profileId.equals(profileId) & q.workId.equals(workId),
            ))
            .go();
        await _renumber(profileId);
      });

  /// Drag-reorder in the queue view: moves [workId] to [newPosition]
  /// (0-indexed, clamped to the queue's bounds) and renumbers everyone
  /// between the old and new spot.
  Future<void> reorder({
    required int profileId,
    required int workId,
    required int newPosition,
  }) => transaction(() async {
    final rows = await queueOf(profileId);
    final without = [
      for (final r in rows)
        if (r.workId != workId) r,
    ];
    final moved = rows.firstWhere((r) => r.workId == workId);
    final clamped = newPosition.clamp(0, without.length);
    without.insert(clamped, moved);
    for (var i = 0; i < without.length; i++) {
      if (without[i].position == i) continue;
      await (update(queueTable)..where((q) => q.id.equals(without[i].id)))
          .write(QueueTableCompanion(position: Value(i)));
    }
  });

  Future<void> _renumber(int profileId) async {
    final rows = await queueOf(profileId);
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].position == i) continue;
      await (update(queueTable)..where((q) => q.id.equals(rows[i].id))).write(
        QueueTableCompanion(position: Value(i)),
      );
    }
  }
}

/// One library work as the query model sees it: the episode row when it
/// has one (only `kind == 'episode'` works do) and the feed title —
/// nullable because most library kinds (book/article/note) have neither.
typedef LibraryQueryEntry = ({Work work, Episode? episode, String? feedTitle});

/// The library screen's join query plus saved-view CRUD (Campaign 5 Phase
/// 2). A separate accessor from [FeedsDao] and [SpineDao] rather than
/// bolted onto either — it reads across all three of their tables
/// (Works, Episodes, Feeds) plus owns [SavedViews] outright.
@DriftAccessor(tables: [SavedViews, Works, Episodes, Feeds])
class LibraryDao extends DatabaseAccessor<AppDatabase> with _$LibraryDaoMixin {
  LibraryDao(super.db);

  /// Every work in a profile's library, left-joined onto its episode row
  /// and feed title — the fields [LibraryQuery] evaluation needs
  /// (feed/source, read state) that [SpineDao.worksOf] alone doesn't
  /// carry. A left join, not inner: most library kinds have no episode
  /// row at all, and must still appear.
  ///
  /// Campaign 9 Phase 4 ("the feed becomes honest reading"): an ephemeron
  /// work never appears here — that's what the river is for, and every
  /// feed item arrives as one (ADR-0002) whether or not it's ever kept.
  /// [SpineDao.promoteWork] (the river's Keep gesture) flips persistence
  /// to 'work', at which point the SAME query starts returning it — no
  /// separate refresh path exists or is needed.
  Future<List<LibraryQueryEntry>> libraryQueryEntriesOf(int profileId) async {
    final q = select(works).join([
      leftOuterJoin(episodes, episodes.workId.equalsExp(works.id)),
      leftOuterJoin(feeds, feeds.id.equalsExp(episodes.feedId)),
    ])
      ..where(works.profileId.equals(profileId) &
          works.persistence.isNotValue('ephemeron'));
    final rows = await q.get();
    return [
      for (final r in rows)
        (
          work: r.readTable(works),
          episode: r.readTableOrNull(episodes),
          feedTitle: r.readTableOrNull(feeds)?.title,
        )
    ];
  }

  /// A profile's saved views in chip order (position ascending).
  Future<List<SavedViewRow>> savedViewsOf(int profileId) =>
      (select(savedViews)
            ..where((v) => v.profileId.equals(profileId))
            ..orderBy([(v) => OrderingTerm.asc(v.position)]))
          .get();

  /// Appends a new saved view at the tail — the chips row grows to the
  /// right, matching how the queue and Up Next append (P4 mercy #3).
  Future<int> createSavedView(
      {required int profileId,
      required String name,
      required String queryJson,
      required int nowMs}) async {
    final existing = await savedViewsOf(profileId);
    return into(savedViews).insert(SavedViewsCompanion.insert(
        profileId: profileId,
        name: name,
        queryJson: queryJson,
        position: existing.length,
        createdAtMs: nowMs));
  }

  /// Deletes one saved view and renumbers what remains contiguously —
  /// [QueueDao.remove]'s renumber-after-delete shape.
  Future<void> deleteSavedView(int id) => transaction(() async {
        final row =
            await (select(savedViews)..where((v) => v.id.equals(id)))
                .getSingleOrNull();
        await (delete(savedViews)..where((v) => v.id.equals(id))).go();
        if (row != null) await _renumberSavedViews(row.profileId);
      });

  /// Drag-reorder: moves [viewId] to [newPosition] (0-indexed, clamped)
  /// and renumbers everyone between the old and new spot —
  /// [QueueDao.reorder]'s shape, over saved views instead of the queue.
  Future<void> reorderSavedView(
      {required int profileId,
      required int viewId,
      required int newPosition}) =>
      transaction(() async {
        final rows = await savedViewsOf(profileId);
        final without = [for (final r in rows) if (r.id != viewId) r];
        final moved = rows.firstWhere((r) => r.id == viewId);
        final clamped = newPosition.clamp(0, without.length);
        without.insert(clamped, moved);
        for (var i = 0; i < without.length; i++) {
          if (without[i].position == i) continue;
          await (update(savedViews)
                ..where((v) => v.id.equals(without[i].id)))
              .write(SavedViewsCompanion(position: Value(i)));
        }
      });

  Future<void> _renumberSavedViews(int profileId) async {
    final rows = await savedViewsOf(profileId);
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].position == i) continue;
      await (update(savedViews)..where((v) => v.id.equals(rows[i].id)))
          .write(SavedViewsCompanion(position: Value(i)));
    }
  }
}

/// Campaign 7 ("audiobooks are a door", ADR-0013): the audiobook work
/// type's own settings row and its ordered file list.
@DriftAccessor(tables: [Audiobooks, AudiobookFiles, Works])
class AudiobooksDao extends DatabaseAccessor<AppDatabase>
    with _$AudiobooksDaoMixin {
  AudiobooksDao(super.db);

  /// Creates the settings row import always writes — unlike [Feeds]'s
  /// playback columns (which start out absent until a feed's own
  /// settings screen first saves them), an audiobook's row exists from
  /// the moment the work does, since import is this table's only writer
  /// of the row itself.
  Future<void> insertAudiobook(int workId) => into(
    audiobooks,
  ).insert(AudiobooksCompanion.insert(workId: Value(workId)));

  Future<AudiobookRow?> audiobookOf(int workId) =>
      (select(audiobooks)..where((a) => a.workId.equals(workId)))
          .getSingleOrNull();

  /// Null clears the override back to deferring to the player's global
  /// speed — same law as [FeedsDao.updatePlaybackSettings].
  Future<void> setSpeedOverride(int workId, double? speed) =>
      (update(audiobooks)..where((a) => a.workId.equals(workId))).write(
        AudiobooksCompanion(speedOverride: Value(speed)),
      );

  /// Inserts [paths] as this audiobook's file list, already in PLAYBACK
  /// order — ordering is the caller's job (the pure
  /// `orderAudiobookFiles` in intake_core), this just persists it as
  /// fileIdx = list index.
  Future<void> insertFiles(int workId, List<String> paths) => batch(
    (b) => b.insertAll(audiobookFiles, [
      for (var i = 0; i < paths.length; i++)
        AudiobookFilesCompanion.insert(
          workId: workId,
          fileIdx: i,
          path: paths[i],
        ),
    ]),
  );

  Future<List<AudiobookFileRow>> filesOf(int workId) =>
      (select(audiobookFiles)
            ..where((f) => f.workId.equals(workId))
            ..orderBy([(f) => OrderingTerm.asc(f.fileIdx)]))
          .get();

  /// The library tile's progress denominator (ADR-0013) — how many files
  /// this audiobook has, without loading every row just to count them.
  Future<int> fileCountOf(int workId) async {
    final c = countAll();
    final q = selectOnly(audiobookFiles)
      ..addColumns([c])
      ..where(audiobookFiles.workId.equals(workId));
    return (await q.getSingle()).read(c) ?? 0;
  }

  /// Learned lazily the first time a file actually plays
  /// ([PlayerController]'s duration-stream handler) — see
  /// [AudiobookFiles.durationMs]'s own doc comment for why nothing
  /// probes this at import.
  Future<void> setFileDuration(int workId, int fileIdx, int durationMs) =>
      (update(audiobookFiles)..where(
            (f) => f.workId.equals(workId) & f.fileIdx.equals(fileIdx),
          ))
          .write(AudiobookFilesCompanion(durationMs: Value(durationMs)));
}

/// A river row: the spine work plus its river metadata and feed title.
typedef RiverEntry = ({Work work, Episode episode, String feedTitle});

@DriftAccessor(tables: [Feeds, Episodes, Works, PlayerPositions])
class FeedsDao extends DatabaseAccessor<AppDatabase> with _$FeedsDaoMixin {
  FeedsDao(super.db);

  Future<int> insertFeed({
    required int profileId,
    required String url,
    String title = '',
    bool autoDownload = false,
  }) => into(feeds).insert(
    FeedsCompanion.insert(
      profileId: profileId,
      url: url,
      title: Value(title),
      autoDownload: Value(autoDownload),
    ),
  );

  Future<List<Feed>> feedsOf(int profileId) =>
      (select(feeds)
            ..where((f) => f.profileId.equals(profileId))
            ..orderBy([(f) => OrderingTerm.asc(f.id)]))
          .get();

  Future<Feed?> feedByUrl(int profileId, String url) =>
      (select(feeds)
            ..where((f) => f.profileId.equals(profileId) & f.url.equals(url)))
          .getSingleOrNull();

  Future<Feed?> feedById(int id) =>
      (select(feeds)..where((f) => f.id.equals(id))).getSingleOrNull();

  /// Per-podcast playback settings (P4 mercy #2) plus the storage setting
  /// (P4 "archive, never forget"). Every argument's null means "clear this
  /// back to deferring to the app / keeping everything" — none of them are
  /// left-alone-if-absent like [updateRefreshState]'s validators, since the
  /// settings screen always writes its full, current form state.
  Future<void> updatePlaybackSettings(
    int feedId, {
    double? speedOverride,
    int? skipIntroSeconds,
    int? skipOutroSeconds,
    int? keepLatestAudio,
    bool? dspEnabled,
  }) => (update(feeds)..where((f) => f.id.equals(feedId))).write(
    FeedsCompanion(
      speedOverride: Value(speedOverride),
      skipIntroSeconds: Value(skipIntroSeconds),
      skipOutroSeconds: Value(skipOutroSeconds),
      keepLatestAudio: Value(keepLatestAudio),
      dspEnabled: Value(dspEnabled),
    ),
  );

  /// Persists the outcome of a refresh: adopted title, validators, and the
  /// breaker's serialized state. Null validators clear the column — the
  /// caller passes the state's current values, which already implement the
  /// donor's keep-old-when-absent law.
  ///
  /// [nextPageUrl] only touches the column when [updateNextPageUrl] is true
  /// (the fresh-parse path, where a null value means the host's archive
  /// link is genuinely gone now). A non-fresh refresh (304/throttled/error)
  /// has no new body to learn that from, so it omits both and the column
  /// keeps whatever it already held. [imageUrl]/[updateImageUrl] (Campaign 9
  /// Phase 5) follow the identical shape for the channel artwork URL.
  Future<void> updateRefreshState(
    int feedId, {
    required String title,
    required String? etag,
    required String? lastModified,
    required String breakerJson,
    String? nextPageUrl,
    bool updateNextPageUrl = false,
    String? imageUrl,
    bool updateImageUrl = false,
  }) => (update(feeds)..where((f) => f.id.equals(feedId))).write(
    FeedsCompanion(
      title: Value(title),
      etag: Value(etag),
      lastModified: Value(lastModified),
      breakerJson: Value(breakerJson),
      nextPageUrl: updateNextPageUrl
          ? Value(nextPageUrl)
          : const Value.absent(),
      imageUrl: updateImageUrl ? Value(imageUrl) : const Value.absent(),
    ),
  );

  Future<void> setAutoDownload(int feedId, bool on) =>
      (update(feeds)..where((f) => f.id.equals(feedId))).write(
        FeedsCompanion(autoDownload: Value(on)),
      );

  Future<void> insertEpisode({
    required int workId,
    required int feedId,
    required String guid,
    String? enclosureUrl,
    int? durationMs,
    required int publishedAtMs,
  }) => into(episodes).insert(
    EpisodesCompanion.insert(
      workId: Value(workId),
      feedId: feedId,
      guid: guid,
      enclosureUrl: Value(enclosureUrl),
      durationMs: Value(durationMs),
      publishedAtMs: publishedAtMs,
    ),
  );

  Future<Episode?> episodeOf(int workId) => (select(
    episodes,
  )..where((e) => e.workId.equals(workId))).getSingleOrNull();

  /// P4 "archive, never forget": marks (or clears, given null) when this
  /// episode's downloaded audio FILE was evicted. Never touches the row
  /// itself — the row's continued existence IS the promise.
  Future<void> setArchived(int workId, int? archivedAtMs) =>
      (update(episodes)..where((e) => e.workId.equals(workId))).write(
        EpisodesCompanion(archivedAtMs: Value(archivedAtMs)),
      );

  /// The offline DSP preprocess's (Campaign 6, ADR-0012) atomic-promote
  /// write: both durations land together, in the SAME call the pipeline
  /// makes right after the processed file replaces the playable one —
  /// never one without the other, so a partially-set pair can never exist
  /// for the time-saved counter to misread.
  Future<void> setDspResult(
    int workId, {
    required int originalDurationMs,
    required int processedDurationMs,
  }) => (update(episodes)..where((e) => e.workId.equals(workId))).write(
    EpisodesCompanion(
      dspOriginalDurationMs: Value(originalDurationMs),
      dspProcessedDurationMs: Value(processedDurationMs),
    ),
  );

  /// This feed's rules (Campaign 5 Phase 3) — see [Feeds.rulesJson].
  Future<void> setRules(int feedId, String rulesJson) =>
      (update(feeds)..where((f) => f.id.equals(feedId)))
          .write(FeedsCompanion(rulesJson: Value(rulesJson)));

  /// Cross-feed dedup candidates: every currently-visible (not already
  /// suppressed) episode in a profile's river, with what
  /// `feed_dedup.dart`'s pure [findDuplicates] needs to compare them —
  /// nothing else. Excluding already-suppressed rows keeps a
  /// [duplicateOfWorkId] always pointing at a non-suppressed root rather
  /// than chaining through another suppressed row.
  Future<List<({int workId, int feedId, String? sourceUrl, String title,
      int publishedAtMs})>> dedupCandidatesOf(int profileId) async {
    final q = select(episodes).join([
      innerJoin(works, works.id.equalsExp(episodes.workId)),
    ])
      ..where(works.profileId.equals(profileId) &
          episodes.dedupReason.isNull());
    final rows = await q.get();
    return [
      for (final r in rows)
        (
          workId: r.readTable(works).id,
          feedId: r.readTable(episodes).feedId,
          sourceUrl: r.readTable(works).sourceUrl,
          title: r.readTable(works).title,
          publishedAtMs: r.readTable(episodes).publishedAtMs,
        )
    ];
  }

  /// Suppresses one episode as a cross-feed duplicate — hidden from
  /// [riverItems], the row untouched.
  Future<void> setDedup(int workId,
          {required String reason, required int canonicalWorkId}) =>
      (update(episodes)..where((e) => e.workId.equals(workId))).write(
          EpisodesCompanion(
              dedupReason: Value(reason),
              duplicateOfWorkId: Value(canonicalWorkId)));

  /// Un-suppresses one episode — [deleteWork] calls this on anything
  /// pointing at a work it is about to remove, so a suppression can never
  /// quietly outlive the canonical row it names.
  Future<void> clearDedup(int workId) =>
      (update(episodes)..where((e) => e.workId.equals(workId))).write(
          const EpisodesCompanion(
              dedupReason: Value(null), duplicateOfWorkId: Value(null)));

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
      ..where(works.profileId.equals(profileId) &
          episodes.dedupReason.isNull())
      ..orderBy([OrderingTerm.desc(episodes.publishedAtMs)]);
    final rows = await q.get();
    return [
      for (final r in rows)
        (
          work: r.readTable(works),
          episode: r.readTable(episodes),
          feedTitle: r.readTable(feeds).title,
        ),
    ];
  }

  /// One feed's own episodes, newest first — the feed detail screen's
  /// query (unlike [riverItems], scoped to a single feed, not a profile's
  /// whole river).
  Future<List<({Work work, Episode episode})>> episodesOfFeed(
    int feedId,
  ) async {
    final q =
        select(
            episodes,
          ).join([innerJoin(works, works.id.equalsExp(episodes.workId))])
          ..where(episodes.feedId.equals(feedId))
          ..orderBy([OrderingTerm.desc(episodes.publishedAtMs)]);
    final rows = await q.get();
    return [
      for (final r in rows)
        (work: r.readTable(works), episode: r.readTable(episodes)),
    ];
  }

  Future<void> markRead(int workId, int nowMs) =>
      (update(episodes)..where((e) => e.workId.equals(workId))).write(
        EpisodesCompanion(readAtMs: Value(nowMs)),
      );

  /// General read-state setter — Undo's restore path for [markRead]
  /// (Campaign 5's Keep and Let-it-pass are both undoable to whatever
  /// readAtMs was before, verbatim, including null).
  Future<void> setReadAt(int workId, int? ms) =>
      (update(episodes)..where((e) => e.workId.equals(workId)))
          .write(EpisodesCompanion(readAtMs: Value(ms)));

  Future<void> setDuration(int workId, int durationMs) =>
      (update(episodes)..where((e) => e.workId.equals(workId))).write(
        EpisodesCompanion(durationMs: Value(durationMs)),
      );

  /// [fileIdx] (Campaign 7, ADR-0013) is which file of a multi-file
  /// audiobook [tMs] is relative to; 0 (the default, and every
  /// pre-campaign caller) for a single-file work, where there is only
  /// ever "file 0".
  Future<void> savePlayerPosition({
    required int profileId,
    required int workId,
    required int tMs,
    int fileIdx = 0,
  }) => into(playerPositions).insertOnConflictUpdate(
    PlayerPositionsCompanion.insert(
      profileId: profileId,
      workId: workId,
      tMs: tMs,
      fileIdx: Value(fileIdx),
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    ),
  );

  Future<PlayerPosition?> playerPosition({
    required int profileId,
    required int workId,
  }) =>
      (select(playerPositions)..where(
            (p) => p.profileId.equals(profileId) & p.workId.equals(workId),
          ))
          .getSingleOrNull();

  Future<List<PlayerPosition>> allPlayerPositions() =>
      select(playerPositions).get();

  /// Deleting a feed takes its unpromoted ephemera with it (ADR-0003 law 2);
  /// a promoted work belongs to the library now — only its river metadata
  /// goes (its sourceUrl still carries the enclosure).
  Future<void> deleteFeedCascade(int feedId) => transaction(() async {
    final rows = await (select(episodes)..where((e) => e.feedId.equals(feedId)))
        .join([innerJoin(works, works.id.equalsExp(episodes.workId))])
        .get();
    for (final r in rows) {
      final work = r.readTable(works);
      if (work.persistence == 'ephemeron') {
        await db.spineDao.deleteWork(work.id);
      } else {
        await (delete(episodes)..where((e) => e.workId.equals(work.id))).go();
      }
    }
    await (delete(feeds)..where((f) => f.id.equals(feedId))).go();
  });
}

/// One course's mastery line on the dashboard: how much of it is built.
typedef CourseMastery = ({String title, int mastered, int total});

/// The parent dashboard's per-profile LIFETIME BUILT view (P5). ADR-0003
/// law 5: additive totals of what exists — works kept, works finished,
/// cards mastered, listening reached, words collected, active reading
/// days (Campaign 4 Phase 5's [ReadingDays] addition). Every number comes
/// from tables the features already write; the dashboard adds no
/// bookkeeping of its own and nothing here can express a streak.
///
/// [listeningMs] is the furthest audio POSITION reached, summed across
/// works (max of raw/aligned per work, see below) — NOT measured
/// wall-clock time spent listening. The common straight-through-no-
/// seeking case makes these nearly the same number, but re-listening to
/// the same passage or seeking around can make them diverge; this field
/// has carried that exact meaning since before Campaign 4 and Phase 5
/// keeps it, rather than inventing a real duration tracker this pass.
typedef LifetimeBuilt = ({
  int worksKept,
  int worksFinished,
  int cardsMastered,
  int wordsCollected,
  int listeningMs,
  int timeSavedMs,
  int activeReadingDays,
  CourseMastery? currentCourse,
});

/// The household layer over the per-profile app: the parent-PIN row, profile
/// rename/delete (the PIN-gated operations), and the dashboard stats.
@DriftAccessor(
  tables: [
    HouseholdPin,
    Profiles,
    Works,
    Positions,
    PlayerPositions,
    Alignments,
    Feeds,
    Episodes,
    Courses,
    Cards,
    Revlog,
    WordLedger,
    ReadingDays,
  ],
)
class HouseholdDao extends DatabaseAccessor<AppDatabase>
    with _$HouseholdDaoMixin {
  HouseholdDao(super.db);

  static const _pinRowId = 0;

  Future<HouseholdPinRow?> readPin() => (select(
    householdPin,
  )..where((p) => p.id.equals(_pinRowId))).getSingleOrNull();

  /// Upserts THE pin row — set and change are the same write; the
  /// current-PIN-required law lives in ParentPinService, not here.
  Future<void> writePin({required String salt, required String hash}) =>
      into(householdPin).insertOnConflictUpdate(
        HouseholdPinCompanion.insert(
          id: Value(_pinRowId),
          salt: salt,
          hash: hash,
        ),
      );

  Future<void> clearPin() =>
      (delete(householdPin)..where((p) => p.id.equals(_pinRowId))).go();

  Future<void> renameProfile(int profileId, String name) =>
      (update(profiles)..where((p) => p.id.equals(profileId))).write(
        ProfilesCompanion(name: Value(name)),
      );

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
      final cardRows = await (select(
        cards,
      )..where((x) => x.courseId.equals(c.id))).get();
      for (final card in cardRows) {
        await (delete(revlog)..where((r) => r.cardId.equals(card.id))).go();
      }
      await (delete(cards)..where((x) => x.courseId.equals(c.id))).go();
      await (delete(courses)..where((x) => x.id.equals(c.id))).go();
    }
    await (delete(
      wordLedger,
    )..where((w) => w.profileId.equals(profileId))).go();
    // Campaign 4 Phase 5: ReadingDays carries a Profiles FK too — left
    // out here it fails the delete outright with a FOREIGN KEY
    // constraint error, not a silent orphan.
    await (delete(
      readingDays,
    )..where((r) => r.profileId.equals(profileId))).go();
    await (delete(profiles)..where((p) => p.id.equals(profileId))).go();
  });

  /// The dashboard query: what this reader has built, from existing tables
  /// only. "Mastered" is study_core's own threshold (interval has reached
  /// [masteryIntervalDays]); the current course is the most recent import.
  Future<LifetimeBuilt> lifetimeBuiltOf(
    int profileId, {
    int masteryIntervalDays = 7,
  }) async {
    final workRows = await db.spineDao.worksOf(profileId);
    final worksKept = workRows.where((w) => w.persistence == 'work').length;
    final worksFinished = workRows
        .where((w) => w.finishedEpochDay != null)
        .length;

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
    final rawRows = await (select(
      playerPositions,
    )..where((p) => p.profileId.equals(profileId))).get();
    for (final r in rawRows) {
      reached[r.workId] = r.tMs;
    }
    final aligned =
        await (select(positions).join([
              innerJoin(
                alignments,
                alignments.workId.equalsExp(positions.workId) &
                    alignments.segmentIdx.equalsExp(positions.segmentIdx),
              ),
            ])..where(
              positions.profileId.equals(profileId) &
                  positions.lastModality.equals('listen'),
            ))
            .get();
    for (final r in aligned) {
      final workId = r.readTable(positions).workId;
      final end = r.readTable(alignments).tEndMs;
      if (end > (reached[workId] ?? 0)) reached[workId] = end;
    }
    final listeningMs = reached.values.fold(0, (a, b) => a + b);

    // Offline DSP (Campaign 6, ADR-0012): the lifetime "time saved"
    // counter — the difference between original and processed durations,
    // summed across every episode of this profile that has actually been
    // processed (both columns set together, in one write — see
    // FeedsDao.setDspResult — so a partial pair never happens). Never
    // negative per episode, matching the pure `timeSavedMs` law
    // `dsp_params.dart` unit-tests independently.
    final episodeRows = await (select(episodes).join([
      innerJoin(works, works.id.equalsExp(episodes.workId)),
    ])..where(works.profileId.equals(profileId))).get();
    var timeSavedMs = 0;
    for (final r in episodeRows) {
      final e = r.readTable(episodes);
      final original = e.dspOriginalDurationMs;
      final processed = e.dspProcessedDurationMs;
      if (original == null || processed == null) continue;
      final diff = original - processed;
      if (diff > 0) timeSavedMs += diff;
    }

    final rdc = countAll();
    final rdq = selectOnly(readingDays)
      ..addColumns([rdc])
      ..where(readingDays.profileId.equals(profileId));
    final activeReadingDays = (await rdq.getSingle()).read(rdc) ?? 0;

    return (
      worksKept: worksKept,
      worksFinished: worksFinished,
      cardsMastered: cardsMastered,
      wordsCollected: wordsCollected,
      listeningMs: listeningMs,
      timeSavedMs: timeSavedMs,
      activeReadingDays: activeReadingDays,
      currentCourse: currentCourse,
    );
  }
}

@DriftDatabase(
    tables: [Profiles, Works, Segments, Layers, Alignments, Positions, Feeds,
        Episodes, PlayerPositions, Courses, Cards, Revlog, JobsTable,
        WordLedger, HouseholdPin, Captures, DailyReviewCards, QueueTable,
        TranslationSentences, SavedViews, Audiobooks, AudiobookFiles,
        ReadingDays],
    daos: [ProfilesDao, SpineDao, FeedsDao, StudyDao, JobsDao, LedgerDao,
        HouseholdDao, CapturesDao, DailyReviewDao, QueueDao, LibraryDao,
        AudiobooksDao])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);
  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 20;
  // There is no v14: it was reserved for the reader-depth campaign, which
  // landed as v18 after three sibling campaigns merged ahead of it, so the
  // guard chain skips from 13 to 15. Version gaps are harmless — an
  // upgrader below 15 still runs every block below in order.
  //
  // v19 belongs to Campaign 8 "Babel widens" (two blocks below: `works
  // .activeTranslationLang` unconditional, `translationSentences.engine`
  // guarded on `from >= 13`). This branch's own change (Campaign 9 Phase 5,
  // feeds.imageUrl) chains after both as v20 — an upgrader sitting anywhere
  // below 20 still runs every block below exactly once, in order, same as
  // every gap above.

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
          if (from >= 2 && from < 8) {
            // RFC 5005 paged-feed following (see [Feeds.nextPageUrl]).
            // Guarded on from >= 2: a from < 2 upgrade just created `feeds`
            // fresh, via the current (already-nextPageUrl-bearing) class
            // definition — addColumn there would be a duplicate column.
            await m.addColumn(feeds, feeds.nextPageUrl);
          }
          if (from < 9) {
            // The study crown (see [Profiles.scheduler]).
            await m.addColumn(profiles, profiles.scheduler);
          }
          if (from < 10) {
            // The study crown, Phase 2 (see [Captures]).
            await m.createTable(captures);
          }
          if (from < 11) {
            // The study crown, Phase 1 (see [DailyReviewCards]).
            await m.createTable(dailyReviewCards);
          }
          if (from < 12) {
            // Campaign 1 ("the player earns love"): per-podcast playback
            // settings, the Up Next queue, and audio-only eviction that
            // never deletes an episode row.
            if (from >= 2) {
              // feeds/episodes exist from here on. A migration that starts
              // BELOW v2 just created them fresh a few lines above (the
              // `from < 2` block's createTable uses the CURRENT table
              // definition, which already carries every column below) —
              // adding these again would collide on a duplicate column.
              await m.addColumn(feeds, feeds.speedOverride);
              await m.addColumn(feeds, feeds.skipIntroSeconds);
              await m.addColumn(feeds, feeds.skipOutroSeconds);
              await m.addColumn(feeds, feeds.keepLatestAudio);
              await m.addColumn(episodes, episodes.archivedAtMs);
            }
            await m.addColumn(profiles, profiles.keepFinishedInQueue);
            await m.createTable(queueTable);
          }
          if (from < 13) {
            // ADR-0008 "Babel" Phase 3: the per-work Spanish translation
            // layer — sentence-indexed rows (finer than [Layers]) plus the
            // scroll-mode display toggle on the work itself (mirrors
            // [Works.pinned], a plain per-work bool). No `from >=` lower
            // bound needed: unlike `feeds` above, neither `works` nor
            // `translationSentences` is ever freshly created by an earlier
            // block with this column/table already present, so addColumn/
            // createTable here is safe for any from < 13.
            await m.addColumn(works, works.showTranslationLayer);
            await m.createTable(translationSentences);
          }
          if (from < 15) {
            // Campaign 5 ("triage & rules") Phase 2: saved library filters
            // (see [SavedViews]). A brand-new table, so no `from >= 2`
            // guard is needed the way [Feeds.nextPageUrl] and Campaign 1's
            // columns needed one — nothing before this ever created it.
            await m.createTable(savedViews);
            if (from >= 2) {
              // Phase 3: per-feed rules and cross-feed dedup — feeds and
              // episodes exist from here on (see the v12 block's own
              // note for why this guard exists).
              await m.addColumn(feeds, feeds.rulesJson);
              await m.addColumn(episodes, episodes.dedupReason);
              await m.addColumn(episodes, episodes.duplicateOfWorkId);
            }
          }
          if (from < 16) {
            // Campaign 6 ("the DSP mountain", ADR-0012): the offline
            // trim-silence/loudness preprocess — per-feed/global opt-in
            // and the stored original/processed durations the lifetime
            // "time saved" counter sums.
            if (from >= 2) {
              // feeds/episodes exist from here on — see the v12 block's
              // own comment for why a from < 2 upgrade must NOT repeat
              // this (the fresh create already carries these columns).
              await m.addColumn(feeds, feeds.dspEnabled);
              await m.addColumn(episodes, episodes.dspOriginalDurationMs);
              await m.addColumn(episodes, episodes.dspProcessedDurationMs);
            }
            await m.addColumn(profiles, profiles.dspGlobalDefault);
          }
          if (from < 17) {
            // Campaign 7 ("audiobooks are a door", ADR-0013): the work type
            // itself (Audiobooks settings + AudiobookFiles rows) is entirely
            // new — never created anywhere else, so unconditional here,
            // exactly like courses/cards/jobsTable/wordLedger before it.
            await m.createTable(audiobooks);
            await m.createTable(audiobookFiles);
            if (from >= 2) {
              // playerPositions exists from v2 on. A from < 2 upgrade just
              // created it fresh a few lines up, via the CURRENT (already
              // fileIdx-bearing) class definition — addColumn there would be
              // a duplicate column, the same reasoning as every column
              // addition above.
              await m.addColumn(playerPositions, playerPositions.fileIdx);
            }
            if (from >= 10) {
              // captures exists from v10 on — same reasoning, different
              // version, because captures (unlike playerPositions) wasn't
              // part of the v2 baseline.
              await m.addColumn(captures, captures.fileIdx);
            }
          }
          if (from < 18) {
            // Campaign 4: reader depth & delight — the whole hop lands
            // together even though [ReadingDays] isn't read until Phase 5
            // (see [Profiles.readerPrefsJson]): one hop is spent once.
            //
            // DELIBERATELY no `from >= 2` here, unlike feeds.nextPageUrl
            // two blocks up: that guard exists because feeds is CREATED
            // fresh inside `if (from < 2)`, via the current (already-
            // nextPageUrl-bearing) class definition, so an unconditional
            // addColumn there would double-add it. profiles is never
            // created inside onUpgrade at all — a from=1 database already
            // has the table (every prior hop's own profiles addColumn,
            // from<7 and from<9, carries no lower bound either) — so a
            // `from >= 2` guard here would SKIP this column entirely for a
            // from=1 upgrade. Verified empirically: a from>=2 guard here
            // reproduces "Null check operator used on a null value" in
            // $ProfilesTable.map on a from=1 fixture (the profiles table
            // lacking reader_prefs_json), which crashes the very first
            // ReaderScreen._load() call. Flagged to the orchestrator with
            // this evidence; kept as `from < 18` pending its reply.
            await m.addColumn(profiles, profiles.readerPrefsJson);
            await m.createTable(readingDays);
          }
          if (from < 19) {
            // Campaign 8 "Babel widens" Phase 1: which language a work's
            // translation layer refers to (see [Works
            // .activeTranslationLang]). No lower bound — `works`, like
            // `profiles`, is never created fresh inside onUpgrade at
            // all, so every path that reaches here still needs it
            // added, the same reasoning as `works.showTranslationLayer`
            // itself (the `from < 13` block above) and
            // `profiles.readerPrefsJson` (the `from < 18` block).
            await m.addColumn(works, works.activeTranslationLang);
          }
          if (from >= 13 && from < 19) {
            // Campaign 8 "Babel widens" Phase 5: which engine produced a
            // stored translated sentence (see [TranslationSentences
            // .engine]). Guarded on `from >= 13`, NOT unconditional —
            // unlike `works`/`profiles` elsewhere in this file,
            // `translationSentences` IS created fresh inside onUpgrade,
            // by the `from < 13` block above. That block's own
            // `createTable` always uses the CURRENT (this file's, right
            // now) table definition, which already carries `engine` —
            // so a `from < 13` upgrade already has this column the
            // moment `if (from < 13)` finishes, and an unconditional
            // addColumn here would double-add it. A `from >= 13` upgrade
            // is the only case where `translationSentences` predates
            // this column for real (a genuine historical v13-v18
            // database, built by an older app version that never had
            // it) — verified empirically: all 12 of this repo's
            // seed-and-strip migration fixtures target `from` values
            // between 1 and 12, and every one of them passed unmodified
            // once this guard was added, because `from >= 13` is false
            // for all of them and the column their fresh createTable
            // already carries is never touched again here.
            await m.addColumn(
                translationSentences, translationSentences.engine);
          }
          if (from >= 2 && from < 20) {
            // Campaign 9 Phase 5 ("the river gets faces"): channel artwork
            // URL (see [Feeds.imageUrl]). Guarded on from >= 2 for exactly
            // the reason [Feeds.nextPageUrl] above is: a from < 2 upgrade
            // just created `feeds` fresh, via the current (already-
            // imageUrl-bearing) class definition — addColumn there would
            // be a duplicate column. Chained after both v19 blocks above
            // (Campaign 8 "Babel widens") so an upgrader landing anywhere
            // below 20 runs every hop in order, once each.
            await m.addColumn(feeds, feeds.imageUrl);
          }
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );
}
