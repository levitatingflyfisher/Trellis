/// An episode and its made versions (board-0130, owner: "maybe make it
/// clear how the episodes are related/have a sister episodes section or
/// something that it auto jumps to?"). A made episode is an episode of
/// its own, found by its guid (`spoken:<original id>:<language>`), so
/// both the original's page and each made one's can list the others.
library;

import 'dart:io';

import 'package:drift/drift.dart';

import '../../db/database.dart';
import '../listen/listen.dart' show parseSpokenGuid;

/// One made version: its language, its episode, and whether its audio
/// is on this phone.
typedef MadeVersion = ({String lang, int workId, bool audio});

class EpisodeVersions {
  /// The original episode; the page's own when it is the original.
  final Work original;
  final Episode originalEpisode;

  /// Every made version of [original], by language tag.
  final Map<String, MadeVersion> made;

  const EpisodeVersions({
    required this.original,
    required this.originalEpisode,
    required this.made,
  });

  /// The made version in [lang] whose audio is on this phone, or null.
  MadeVersion? withAudio(String? lang) {
    final v = made[lang];
    return v != null && v.audio ? v : null;
  }
}

/// [episode]'s original and every made version of it. Null when the
/// original of a made episode is gone. [audioFileFor] finds a made
/// episode's audio; without it (the web) none is on the phone.
Future<EpisodeVersions?> loadEpisodeVersions(
  AppDatabase db, {
  required Work work,
  required Episode episode,
  File Function(int workId, String url)? audioFileFor,
}) async {
  var original = work;
  var originalEpisode = episode;
  if (parseSpokenGuid(episode.guid) case (:final originalId, lang: _)) {
    final w = await db.spineDao.workById(originalId);
    final e = await db.feedsDao.episodeOf(originalId);
    if (w == null || e == null) return null;
    original = w;
    originalEpisode = e;
  }
  final rows = await (db.select(db.episodes)
        ..where((e) => e.guid.like('spoken:${original.id}:%')))
      .get();
  final made = <String, MadeVersion>{};
  for (final r in rows) {
    final parsed = parseSpokenGuid(r.guid);
    if (parsed == null || parsed.originalId != original.id) continue;
    final url = r.enclosureUrl;
    final audio = url != null &&
        audioFileFor != null &&
        audioFileFor(r.workId, url).existsSync();
    made[parsed.lang] = (lang: parsed.lang, workId: r.workId, audio: audio);
  }
  return EpisodeVersions(
      original: original, originalEpisode: originalEpisode, made: made);
}
