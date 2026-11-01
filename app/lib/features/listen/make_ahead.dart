/// Make ahead (owner, 10 November 2026: "Yes, for shows I pick"): new
/// episodes of a show the person switched on are translated and voiced
/// before anyone taps, so the row's second button plays at once.
///
/// This file is the record and the rules, with no engine in it: which
/// shows are on, which episodes were picked, and what comes off the
/// device when the room runs out. [ListenJobs] runs what is picked, one
/// at a time, behind anything a person asked for. ADR-0021 says why it is
/// shaped this way and what Android does not let it promise.
library;

import 'dart:convert';

import '../../db/database.dart';
import '../feeds/auto_download.dart' show pickAutoDownloads;

/// The device setting holding the whole record, as one JSON value so a
/// pick and the show's mark always change together.
const makeAheadKey = 'make_ahead';

/// The device setting: how many gigabytes made-ahead audio may take.
const makeAheadLimitKey = 'make_ahead_limit_gb';

/// At most this many per show, waiting or made and not yet played.
const makeAheadPerShow = 3;

const makeAheadDefaultLimitGb = 2;
const makeAheadLimitChoicesGb = [1, 2, 5, 10];

/// Gigabytes as the app writes sizes everywhere else (`formatBytes`).
int makeAheadLimitBytes(int gb) => gb * 1000000000;

/// A show that is switched on. [after] is the newest episode already
/// passed over: only rows above it are new. [agreedLang] is the language
/// the person agreed to fetch models for on the consent sheet, or null
/// when nothing had to be fetched then.
typedef AheadShow = ({int after, String? agreedLang});

/// One picked episode: waiting while [spokenId] is null, then made.
class AheadEntry {
  const AheadEntry({
    required this.workId,
    required this.feedId,
    required this.publishedAtMs,
    this.spokenId,
    this.lang,
    this.madeAtMs,
    this.tries = 0,
  });

  final int workId;
  final int feedId;
  final int publishedAtMs;
  final int? spokenId;
  final String? lang;
  final int? madeAtMs;

  /// Attempts that failed for a reason of their own.
  final int tries;

  bool get made => spokenId != null;

  AheadEntry withTry() => AheadEntry(
      workId: workId,
      feedId: feedId,
      publishedAtMs: publishedAtMs,
      tries: tries + 1);

  AheadEntry madeAs(int spoken, String language, int nowMs) => AheadEntry(
      workId: workId,
      feedId: feedId,
      publishedAtMs: publishedAtMs,
      spokenId: spoken,
      lang: language,
      madeAtMs: nowMs);

  Map<String, Object?> toJson() => {
        'id': workId,
        'feed': feedId,
        'at': publishedAtMs,
        if (spokenId != null) 'spoken': spokenId,
        if (lang != null) 'lang': lang,
        if (madeAtMs != null) 'made': madeAtMs,
        if (tries > 0) 'tries': tries,
      };

  static AheadEntry? fromJson(Object? m) => switch (m) {
        {'id': final int id, 'feed': final int feed, 'at': final int at} =>
          AheadEntry(
              workId: id,
              feedId: feed,
              publishedAtMs: at,
              spokenId: m['spoken'] as int?,
              lang: m['lang'] as String?,
              madeAtMs: m['made'] as int?,
              tries: m['tries'] as int? ?? 0),
        _ => null,
      };
}

class AheadBook {
  AheadBook({Map<int, AheadShow>? shows, List<AheadEntry>? entries})
      : shows = shows ?? {},
        entries = entries ?? [];

  final Map<int, AheadShow> shows;
  final List<AheadEntry> entries;

  String encode() => jsonEncode({
        'shows': {
          for (final MapEntry(:key, :value) in shows.entries)
            '$key': {'after': value.after, 'agreed': value.agreedLang},
        },
        'entries': [for (final e in entries) e.toJson()],
      });

  /// Null when [raw] is not a record this app wrote.
  static AheadBook? decode(String raw) {
    try {
      if (jsonDecode(raw) case {
        'shows': final Map<String, dynamic> shows,
        'entries': final List<dynamic> entries,
      }) {
        return AheadBook(shows: {
          for (final MapEntry(:key, :value) in shows.entries)
            if ((int.tryParse(key), value)
                case (final int id, {'after': final int after}))
              id: (after: after, agreedLang: value['agreed'] as String?),
        }, entries: [
          for (final m in entries) ?AheadEntry.fromJson(m),
        ]);
      }
    } catch (_) {
      // Falls through: not a record.
    }
    return null;
  }
}

/// Reads the record. One of the wrong shape is set aside and the record
/// starts empty: a bad value must never stop the app from opening.
Future<AheadBook> readAheadBook(AppDatabase db) async {
  final raw = await db.deviceSettingsDao.read(makeAheadKey);
  if (raw == null) return AheadBook();
  final book = AheadBook.decode(raw);
  if (book != null) return book;
  await db.deviceSettingsDao.write('$makeAheadKey-unreadable', raw);
  await db.deviceSettingsDao.clear(makeAheadKey);
  return AheadBook();
}

/// The episodes to pick from [episodes] (one show's, any order): new ones
/// above [afterWorkId], newest first, at most [room]. The same test of
/// "new" as auto-download, so a re-parse's fresh ids for old items never
/// count. A spoken row is the app's own output and is never a source.
/// [skip] says an episode is here already or cannot be made.
List<AheadEntry> aheadPicks(
  List<({Work work, Episode episode})> episodes, {
  required int afterWorkId,
  required int room,
  required bool Function(int workId) skip,
}) {
  if (room <= 0) return const [];
  final originals = [
    for (final e in episodes)
      if (!e.episode.guid.startsWith('spoken:')) e,
  ];
  final at = {for (final e in originals) e.work.id: e.episode};
  return [
    for (final p in pickAutoDownloads(originals,
        afterWorkId: afterWorkId,
        cap: room,
        onDisk: (id, _) => skip(id)))
      AheadEntry(
          workId: p.workId,
          feedId: at[p.workId]!.feedId,
          publishedAtMs: at[p.workId]!.publishedAtMs),
  ];
}

/// One made-ahead file, as the room rule sees it.
typedef AheadFile = ({int spokenId, int bytes, int madeAtMs, bool played, bool immune});

/// Which of [files] to remove so the rest fit in [limitBytes], in order:
/// a played one before an unplayed one, and the oldest first within each.
/// An immune one is never removed, though it still takes room.
List<int> audioToRemove(List<AheadFile> files, int limitBytes) {
  var total = files.fold(0, (sum, f) => sum + f.bytes);
  final removable = [
    for (final f in files)
      if (!f.immune) f,
  ]..sort((a, b) => a.played == b.played
      ? a.madeAtMs.compareTo(b.madeAtMs)
      : (a.played ? -1 : 1));
  final out = <int>[];
  for (final f in removable) {
    if (total <= limitBytes) break;
    out.add(f.spokenId);
    total -= f.bytes;
  }
  return out;
}

/// Whether a pass could find anything: a show that is on has a row above
/// its mark. Cheap and rough on purpose, since a pass decides for itself.
/// The feed check that brought the rows in is what marks them due, so the
/// worker writes nothing here (ADR-0021).
Future<bool> makeAheadDue(AppDatabase db) async {
  final book = await readAheadBook(db);
  if (book.entries.any((e) => !e.made)) return true;
  for (final MapEntry(:key, :value) in book.shows.entries) {
    for (final e in await db.feedsDao.episodesOfFeed(key)) {
      if (e.work.id > value.after && !e.episode.guid.startsWith('spoken:')) {
        return true;
      }
    }
  }
  return false;
}
