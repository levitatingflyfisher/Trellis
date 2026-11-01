/// Trellis's own audio_service handler (1.6.0): the one place
/// audio_service's types are used. See playback_session.dart for why the
/// app owns this now.
///
/// It holds no player. Whoever is playing attaches itself, reports what
/// it is doing, and is called back when a button on the lock screen, the
/// notification or a headset is pressed.
library;

import 'dart:async';

import 'package:audio_service/audio_service.dart';

import 'headset_keys.dart';
import 'media_item_mapping.dart';
import 'playback_session.dart';

class TrellisAudioHandler extends BaseAudioHandler implements PlaybackSession {
  /// How far the fast-forward and rewind keys move (some remotes and
  /// keyboards have them): what the plugin this replaces did. The Next
  /// and Previous keys have their own settings (headset_keys.dart).
  static const skipBy = Duration(seconds: 10);

  TrellisAudioHandler({this.clickWindow = const Duration(milliseconds: 400)});

  /// How long a counted click waits for the next one (a one-button
  /// headset; see headset_keys.dart).
  final Duration clickWindow;

  /// What the headset's keys do now, read on each press. Set by the app
  /// once it has a database; null (and any failure to read) means the
  /// defaults.
  Future<HeadsetKeys> Function()? headsetKeys;

  /// "Next episode" and "Previous episode": the shell's player, bound once
  /// there is a reader (bindEpisodeKeys). Null before that and after the
  /// shell goes: the key then does nothing.
  Future<void> Function()? onNextEpisode;
  Future<void> Function()? onPreviousEpisode;

  SessionClient? _client;
  Timer? _holdSeek;
  int _clicks = 0;
  Timer? _clickTimer;

  Future<HeadsetKeys> _keys() async {
    try {
      return await headsetKeys?.call() ?? const HeadsetKeys();
    } catch (_) {
      return const HeadsetKeys();
    }
  }

  /// A press of a headset's, a car's or a remote's button (1.6.0, user:
  /// "Double tap is skip forward 30 seconds. Triple tap is skip forward
  /// episode."). The earbud has already turned its taps into a key: Next
  /// and Previous come here as themselves and do what their settings say.
  /// The play/pause button acts at once, unless clicks are being counted
  /// for a one-button headset: then one click plays or pauses, two are
  /// the Next key and three the Previous, once no further click comes.
  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    switch (button) {
      case MediaButton.next:
        return _key((k) => k.next);
      case MediaButton.previous:
        return _key((k) => k.previous);
      case MediaButton.media:
        if (!(await _keys()).countClicks) return _playOrPause();
        _clicks++;
        _clickTimer?.cancel();
        _clickTimer = Timer(clickWindow, () => unawaited(_settleClicks()));
    }
  }

  Future<void> _settleClicks() async {
    final clicks = _clicks;
    _clicks = 0;
    _clickTimer = null;
    if (clicks <= 1) return _playOrPause();
    return _key(clicks == 2 ? (k) => k.next : (k) => k.previous);
  }

  Future<void> _playOrPause() =>
      playbackState.value.playing ? pause() : play();

  /// A car's or a notification's skip buttons are the same two keys.
  @override
  Future<void> skipToNext() => _key((k) => k.next);

  @override
  Future<void> skipToPrevious() => _key((k) => k.previous);

  Future<void> _key(HeadsetAction Function(HeadsetKeys) pick) async {
    final action = pick(await _keys());
    final by = action.seekBy;
    if (by != null) return _skip(by);
    await (action == HeadsetAction.nextEpisode
            ? onNextEpisode
            : onPreviousEpisode)
        ?.call();
  }

  @override
  void attach(SessionClient client, LockScreenTag tag) {
    _client = client;
    mediaItem.add(MediaItem(
      id: tag.id,
      title: tag.title,
      album: tag.album,
      artUri: tag.artUri,
    ));
  }

  @override
  void report(SessionClient client, SessionState state) {
    if (!identical(client, _client)) return;
    _publish(state);
    // The lock screen draws its seek bar only once it knows the length.
    final item = mediaItem.value;
    final duration = state.duration;
    if (item != null && duration != null && item.duration != duration) {
      mediaItem.add(item.copyWith(duration: duration));
    }
  }

  @override
  void detach(SessionClient client) {
    if (!identical(client, _client)) return;
    _client = null;
    _stopHoldSeek();
    _publish(SessionState.idle);
  }

  void _publish(SessionState state) {
    final idle = state.phase == SessionPhase.idle;
    // Still "playing" at the end of a file and while the next one loads:
    // the engine means to go on, and saying otherwise takes the playback
    // service out of the foreground, where Android will not let it back
    // from behind the screen. Only idle is never playing.
    final playing = state.playing && !idle;
    playbackState.add(PlaybackState(
      controls: [
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
      ],
      // Stop stays out of the compact notification.
      androidCompactActionIndices: const [0],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      processingState: switch (state.phase) {
        SessionPhase.idle => AudioProcessingState.idle,
        SessionPhase.loading => AudioProcessingState.loading,
        SessionPhase.buffering => AudioProcessingState.buffering,
        SessionPhase.ready => AudioProcessingState.ready,
        SessionPhase.completed => AudioProcessingState.completed,
      },
      playing: playing,
      updatePosition: state.position,
      bufferedPosition: state.buffered,
      speed: state.speed,
    ));
  }

  @override
  Future<void> play() async => _client?.play();

  @override
  Future<void> pause() async => _client?.pause();

  @override
  Future<void> seek(Duration position) async => _client?.seek(position);

  /// The notification's Stop, or the system letting the session go. The
  /// client lets its engine go; the session then says idle, which is what
  /// tells the service to stop and take its notification with it. The
  /// client stays attached: if it plays again, the session comes back.
  @override
  Future<void> stop() async {
    _stopHoldSeek();
    final client = _client;
    if (client == null) return;
    await client.stop();
    if (identical(client, _client)) _publish(SessionState.idle);
  }

  @override
  Future<void> fastForward() => _skip(skipBy);

  @override
  Future<void> rewind() => _skip(-skipBy);

  /// A held fast-forward or rewind key: a skip a second while it is held.
  @override
  Future<void> seekForward(bool begin) async => _holdSeekBy(begin, skipBy);

  @override
  Future<void> seekBackward(bool begin) async => _holdSeekBy(begin, -skipBy);

  void _holdSeekBy(bool begin, Duration by) {
    _stopHoldSeek();
    if (!begin) return;
    _holdSeek = Timer.periodic(
        const Duration(seconds: 1), (_) => unawaited(_skip(by)));
  }

  void _stopHoldSeek() {
    _holdSeek?.cancel();
    _holdSeek = null;
  }

  Future<void> _skip(Duration by) async {
    final client = _client;
    if (client == null) return;
    var to = playbackState.value.position + by;
    final length = mediaItem.value?.duration;
    if (length != null && to > length) to = length;
    if (to < Duration.zero) to = Duration.zero;
    await client.seek(to);
  }
}
