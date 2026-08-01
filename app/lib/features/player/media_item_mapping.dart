/// Campaign 9 Phase 2e (ADR-0015 Decision 3): what the lock screen and
/// pull-down tray show for whatever is playing.
///
/// [LockScreenTag] is a plain, plugin-free value — [JustAudioEpisodePlayer]
/// is the only place that ever turns it into just_audio_background's own
/// MediaItem type, the same way [EpisodePlayer] itself stays free of
/// just_audio's own types. [lockScreenTagFor] is a pure function of [Work]
/// plus two caller-supplied hints, so it is testable without a platform
/// channel in reach — the honest boundary this phase draws: what reaches
/// the tag is provable here; how the lock screen RENDERS it is device-only
/// and is not claimed by any test that imports this file.
library;

import 'dart:io';

import '../../db/database.dart';

class LockScreenTag {
  const LockScreenTag({
    required this.id,
    required this.title,
    this.album,
    this.artUri,
  });

  /// [Work.id], stringified — the same identity the cursor law already
  /// keys everything else on.
  final String id;

  /// [Work.title], never invented.
  final String title;
  final String? album;
  final Uri? artUri;
}

/// Builds the lock-screen tag for [work].
///
/// [album] is the caller's to supply — a feed's title for an episode,
/// `null` for an audiobook (which has no feed to name one from). A blank
/// string (a feed whose title was never resolved, [Feed.title]'s own
/// documented default) reads as no album at all rather than a blank line
/// on the lock screen.
///
/// [artworkFile] becomes [LockScreenTag.artUri] only when it actually
/// exists on disk — the SAME `existsSync()` gate the river's own artwork
/// thumbnail uses (Phase 5c): a deterministic path from
/// [DeviceServices.artworkFileFor] is not proof a file was ever
/// downloaded.
LockScreenTag lockScreenTagFor(
  Work work, {
  String? album,
  File? artworkFile,
}) {
  final resolvedAlbum = (album == null || album.isEmpty) ? null : album;
  final art = (artworkFile != null && artworkFile.existsSync())
      ? Uri.file(artworkFile.path)
      : null;
  return LockScreenTag(
    id: work.id.toString(),
    title: work.title,
    album: resolvedAlbum,
    artUri: art,
  );
}
