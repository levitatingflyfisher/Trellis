/// The standalone "Download" door (Campaign 6, Part 2): onto disk without
/// requesting a transcript. Before this campaign, `services.audioFileFor`
/// only ever got written to as a byproduct of transcription — this is the
/// second, independent door, for the plain "listen offline" case, over the
/// SAME resolver `PlayerController` now prefers and `audio_eviction.dart`
/// deletes from.
///
/// One consent chokepoint (the UI calls `confirmDownload` before ever
/// calling [start] — there is no second door, ADR-0003 law 6), the fleet's
/// one download engine (`AudioFetcher`). No persisted job row: the `.part`
/// file `AudioFetcher`'s own resumable engine leaves beside the target IS
/// the resumability checkpoint — the same law the transcribe pipeline's
/// own audio-fetch step already relies on, and proportionate to a single,
/// non-chunked file fetch (no per-unit checkpoint exists to persist).
library;

import 'dart:async';

import 'package:dio/dio.dart' as dio;
import 'package:flutter/foundation.dart';

import '../../services/device_services.dart';

/// One episode's download snapshot, as the UI reads it. The absence of a
/// state entry (see [EpisodeDownloadCoordinator.stateOf]'s default) means
/// "not downloading" — this type never needs an explicit idle variant.
class EpisodeDownloadState {
  final bool downloading;
  final int? receivedBytes;
  final int? totalBytes;
  final String? error;

  const EpisodeDownloadState({
    this.downloading = false,
    this.receivedBytes,
    this.totalBytes,
    this.error,
  });
}

class EpisodeDownloadCoordinator extends ChangeNotifier {
  final DeviceServices services;
  EpisodeDownloadCoordinator({required this.services});

  final Map<int, EpisodeDownloadState> _states = {};
  final Map<int, dio.CancelToken> _tokens = {};

  EpisodeDownloadState stateOf(int workId) =>
      _states[workId] ?? const EpisodeDownloadState();

  /// Disk truth, not cached state — the same check `PlayerController` and
  /// `audio_eviction.dart` make, so this never drifts from what actually
  /// plays.
  bool isDownloaded(int workId, String url) =>
      services.audioFileFor(workId, url).existsSync();

  /// Fetches [url] to `services.audioFileFor(workId, url)`. A no-op if
  /// already on disk or already in flight — the UI's Download button can
  /// be tapped freely without a second fetch racing the first.
  Future<void> start({required int workId, required String url}) async {
    if (_states[workId]?.downloading == true) return;
    if (isDownloaded(workId, url)) return;

    final target = services.audioFileFor(workId, url);
    final token = dio.CancelToken();
    _tokens[workId] = token;
    _states[workId] = const EpisodeDownloadState(downloading: true);
    notifyListeners();

    try {
      // Whichever TransferOutcome comes back, the fetch is over and
      // isDownloaded() now reads the honest disk result — no separate
      // bookkeeping needs to stay in sync with it here.
      await services.audioFetcher.fetch(
        url,
        target,
        cancelToken: token,
        onProgress: (received, total) {
          _states[workId] = EpisodeDownloadState(
            downloading: true,
            receivedBytes: received,
            totalBytes: total,
          );
          notifyListeners();
        },
      );
      _states.remove(workId);
    } catch (err) {
      _states[workId] = EpisodeDownloadState(error: err.toString());
    } finally {
      _tokens.remove(workId);
      notifyListeners();
    }
  }

  /// Stops an in-flight download; the partial stays on disk beside the
  /// target (AudioFetcher's own `.part` law) for a later [start] to
  /// resume from. A no-op if nothing is in flight for [workId].
  void cancel(int workId) => _tokens[workId]?.cancel();
}
