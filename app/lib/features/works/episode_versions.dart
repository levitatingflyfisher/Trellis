/// An episode and its made versions (board-0130, owner: "maybe make it
/// clear how the episodes are related/have a sister episodes section or
/// something that it auto jumps to?"). A made episode is an episode of
/// its own work, a version of the original (1.6.18: the Versions table),
/// so the original's page lists every language it has.
library;

import 'dart:io';


import '../../db/database.dart';

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

/// [work]'s original and every made version of it, from the Versions
/// table (1.6.18). [work] may be the original (with its [episode]) or a
/// version, which has no episode of its own. Null when [work] is neither,
/// or a version's original is gone. [audioFileFor] finds a version's
/// audio; without it (the web) none is on the phone.
Future<EpisodeVersions?> loadEpisodeVersions(
  AppDatabase db, {
  required Work work,
  Episode? episode,
  File Function(int workId, String url)? audioFileFor,
}) async {
  var original = work;
  var originalEpisode = episode;
  if (await db.versionsDao.versionOf(work.id) case final v?) {
    final w = await db.spineDao.workById(v.originalId);
    final e = await db.feedsDao.episodeOf(v.originalId);
    if (w == null || e == null) return null;
    original = w;
    originalEpisode = e;
  }
  if (originalEpisode == null) return null;
  final made = <String, MadeVersion>{};
  for (final v in await db.versionsDao.versionsOf(original.id)) {
    final url = (await db.spineDao.workById(v.workId))?.sourceUrl;
    final audio = url != null &&
        audioFileFor != null &&
        audioFileFor(v.workId, url).existsSync();
    made[v.lang] = (lang: v.lang, workId: v.workId, audio: audio);
  }
  return EpisodeVersions(
      original: original, originalEpisode: originalEpisode, made: made);
}
