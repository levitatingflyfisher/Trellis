/// The clean-up's bulk writes (ADR-0016 section 5). Each action is one
/// transaction however many episodes it touches, with every IN list
/// chunked under SQLite's variable cap (ADR-0017's `deleteWorks` shape).
/// Each returns a [BulkChange] whose [BulkChange.undo] puts back exactly
/// what was there before, because a deliberate bulk change gets a lasting
/// Undo (fleet ruling).
///
/// Kept out of the DAOs on purpose: it reads and writes across episodes,
/// works, places and the queue, and none of it needs generated code.
library;

import 'package:drift/drift.dart';

import 'database.dart';

/// What a bulk action changed, and the way back.
class BulkChange {
  /// How many episodes actually changed; rows already in the asked-for
  /// state are not counted, so a message never claims more than happened.
  final int count;

  /// Whether anything was written at all. A row can change without
  /// counting (a finished one getting its seen day), and that still
  /// needs its way back.
  final bool changed;
  final Future<void> Function() _undo;
  BulkChange(this.count, this._undo, {bool? changed})
      : changed = changed ?? count > 0;

  Future<void> undo() => _undo();
}

class BulkEpisodes {
  final AppDatabase db;
  BulkEpisodes(this.db);

  Future<List<int>> _blank(
      List<int> ids, GeneratedColumn<int> Function($EpisodesTable) column) async {
    final out = <int>[];
    for (final c in chunksForSql(ids)) {
      final q = db.selectOnly(db.episodes)
        ..addColumns([db.episodes.workId])
        ..where(db.episodes.workId.isIn(c) & column(db.episodes).isNull());
      out.addAll([for (final r in await q.get()) r.read(db.episodes.workId)!]);
    }
    return out;
  }

  Future<void> _write(List<int> ids, EpisodesCompanion values) async {
    for (final c in chunksForSql(ids)) {
      await (db.update(db.episodes)..where((e) => e.workId.isIn(c)))
          .write(values);
    }
  }

  /// "Mark played" for many: stamps the played fact and the seen day only
  /// where each is blank, so an earlier finish or seen day survives, and
  /// Undo can blank exactly the ones it filled. Like the single action it
  /// promotes nothing and leaves the finished day alone, so History
  /// (actually listened) is untouched.
  Future<BulkChange> markPlayed(Iterable<int> workIds, {required int nowMs}) {
    final ids = workIds.toSet().toList();
    return db.transaction(() async {
      final unfinished = await _blank(ids, (e) => e.finishedAtMs);
      final unread = await _blank(ids, (e) => e.readAtMs);
      await _write(unfinished, EpisodesCompanion(finishedAtMs: Value(nowMs)));
      await _write(unread, EpisodesCompanion(readAtMs: Value(nowMs)));
      return BulkChange(
          unfinished.length,
          () => db.transaction(() async {
                await _write(unfinished,
                    const EpisodesCompanion(finishedAtMs: Value(null)));
                await _write(
                    unread, const EpisodesCompanion(readAtMs: Value(null)));
              }),
          changed: unfinished.isNotEmpty || unread.isNotEmpty);
    });
  }

  /// "Let it pass" for many: marks seen where not yet seen. The single
  /// gesture restamps an already-seen row; in bulk an old seen day is
  /// worth keeping, and filling only blanks keeps Undo set-based.
  Future<BulkChange> letPass(Iterable<int> workIds, {required int nowMs}) {
    final ids = workIds.toSet().toList();
    return db.transaction(() async {
      final unread = await _blank(ids, (e) => e.readAtMs);
      await _write(unread, EpisodesCompanion(readAtMs: Value(nowMs)));
      return BulkChange(
          unread.length,
          () => db.transaction(() => _write(
              unread, const EpisodesCompanion(readAtMs: Value(null)))));
    });
  }

  /// "Mark unplayed" for many, the same as the single action: forgets the
  /// played fact, the finished day and every saved place. Those are
  /// copied first, whole, so Undo restores History and places verbatim.
  Future<BulkChange> markUnplayed(Iterable<int> workIds,
      {required int profileId}) {
    final ids = workIds.toSet().toList();
    return db.transaction(() async {
      final finishedAt = <int, int>{};
      final finishedDay = <int, int>{};
      final players = <PlayerPosition>[];
      final places = <Position>[];
      for (final c in chunksForSql(ids)) {
        for (final e in await (db.select(db.episodes)
              ..where((e) => e.workId.isIn(c) & e.finishedAtMs.isNotNull()))
            .get()) {
          finishedAt[e.workId] = e.finishedAtMs!;
        }
        for (final w in await (db.select(db.works)
              ..where((w) => w.id.isIn(c) & w.finishedEpochDay.isNotNull()))
            .get()) {
          finishedDay[w.id] = w.finishedEpochDay!;
        }
        players.addAll(await (db.select(db.playerPositions)
              ..where((p) => p.profileId.equals(profileId) & p.workId.isIn(c)))
            .get());
        places.addAll(await (db.select(db.positions)
              ..where((p) => p.profileId.equals(profileId) & p.workId.isIn(c)))
            .get());
      }
      for (final c in chunksForSql(ids)) {
        await (db.update(db.episodes)..where((e) => e.workId.isIn(c)))
            .write(const EpisodesCompanion(finishedAtMs: Value(null)));
        await (db.update(db.works)..where((w) => w.id.isIn(c)))
            .write(const WorksCompanion(finishedEpochDay: Value(null)));
        await (db.delete(db.playerPositions)
              ..where((p) => p.profileId.equals(profileId) & p.workId.isIn(c)))
            .go();
        await (db.delete(db.positions)
              ..where((p) => p.profileId.equals(profileId) & p.workId.isIn(c)))
            .go();
      }
      // An in-progress episode was never finished, yet clearing its place
      // changes it (and takes it out of History), so it counts.
      final touched = {
        ...finishedAt.keys,
        ...finishedDay.keys,
        for (final p in players) p.workId,
        for (final p in places) p.workId,
      };
      return BulkChange(touched.length, () => db.transaction(() async {
            // Grouped by value: a backlog marked played at once shares one
            // stamp, so this is a handful of statements, not one per row.
            for (final g in _byValue(finishedAt).entries) {
              await _write(
                  g.value, EpisodesCompanion(finishedAtMs: Value(g.key)));
            }
            for (final g in _byValue(finishedDay).entries) {
              for (final c in chunksForSql(g.value)) {
                await (db.update(db.works)..where((w) => w.id.isIn(c)))
                    .write(WorksCompanion(finishedEpochDay: Value(g.key)));
              }
            }
            await db.batch((b) {
              b.insertAll(db.playerPositions, players,
                  mode: InsertMode.insertOrReplace);
              b.insertAll(db.positions, places,
                  mode: InsertMode.insertOrReplace);
            });
          }));
    });
  }

  /// Appends the ones not already in the queue, in the order given; queued
  /// ones keep their place. Undo takes out only what this added.
  Future<BulkChange> addToQueue(List<int> workIds,
      {required int profileId, required int nowMs}) {
    return db.transaction(() async {
      final have = {
        for (final r in await db.queueDao.queueOf(profileId)) r.workId,
      };
      final added = [
        for (final id in workIds)
          if (!have.contains(id)) id,
      ];
      await db.queueDao
          .playLastAll(profileId: profileId, workIds: added, nowMs: nowMs);
      return BulkChange(added.length, () => db.transaction(() async {
            for (final c in chunksForSql(added)) {
              await (db.delete(db.queueTable)
                    ..where((q) =>
                        q.profileId.equals(profileId) & q.workId.isIn(c)))
                  .go();
            }
            await _renumber(profileId);
          }));
    });
  }

  /// Positions back to 0..n-1 in their current order, so "the head" is
  /// still the row at 0 after a gap opens.
  Future<void> _renumber(int profileId) async {
    final rows = await db.queueDao.queueOf(profileId);
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].position == i) continue;
      await (db.update(db.queueTable)..where((q) => q.id.equals(rows[i].id)))
          .write(QueueTableCompanion(position: Value(i)));
    }
  }

  static Map<int, List<int>> _byValue(Map<int, int> values) {
    final out = <int, List<int>>{};
    values.forEach((id, v) => (out[v] ??= []).add(id));
    return out;
  }
}
