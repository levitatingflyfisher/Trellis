/// Download first, then play (1.6.0, user: "Play for download then
/// play"): the pieces between the player and the download coordinator,
/// and the words for what the player reports.
library;

import '../../db/database.dart';
import '../feeds/episode_download_coordinator.dart';
import 'player_controller.dart';

/// Begins the download a Play asked for, as an ordinary download by hand:
/// it has its row, shows on Jobs, can be paused, and survives a kill.
/// Null when it must wait for Wi-Fi ("Download only on Wi-Fi" is on and
/// this is mobile data): the episode is left to the next Wi-Fi pass and
/// there is nothing to wait on. One already running is joined.
Future<Future<FetchEnd>?> beginEpisodeFetch(
    EpisodeDownloadCoordinator downloads, Work work, String url) async {
  if (await downloads.waitsForWifi(work.id, url)) {
    await downloads.startByHand(workId: work.id, url: url, title: work.title);
    return null;
  }
  return downloads
      .start(workId: work.id, url: url, title: work.title)
      .then<FetchEnd>((outcome) => switch (outcome) {
            DownloadOutcome.done => FetchEnd.landed,
            DownloadOutcome.paused => FetchEnd.paused,
            DownloadOutcome.failed => FetchEnd.failed,
          });
}

/// What the app says, where the listener is looking, when a Play could
/// not simply play.
String playNoticeWords(PlayNotice notice) => switch (notice) {
      PlayNotice.downloadingFirst =>
        'Downloading first. It plays when it’s ready.',
      PlayNotice.waitingForWifi =>
        'Waiting for Wi-Fi. It downloads when Wi-Fi is back, and you can '
            'play it then.',
      PlayNotice.downloadFailed =>
        'The download didn’t finish, so nothing played. Jobs says why.',
    };
