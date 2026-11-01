/// The media session as the app sees it (1.6.0): what the lock screen,
/// the notification and a headset show and control, one thing at a time.
///
/// Trellis owns this now. Until 1.5.10 the just_audio_background plugin
/// did, with a handler the app could not reach: it told the playback
/// service "not playing" the moment a file ended (so the next queued
/// episode started unprotected behind the screen), it could not map a
/// headset key to anything but "next track", and it served exactly one
/// player, so read aloud could not have a session at all. Plain types
/// only: audio_service lives behind this (trellis_audio_handler.dart), and
/// tests drive a fake.
library;

import 'media_item_mapping.dart';

/// Where the thing in the session is, in the engine's own terms.
enum SessionPhase { idle, loading, buffering, ready, completed }

class SessionState {
  const SessionState({
    this.playing = false,
    this.phase = SessionPhase.idle,
    this.position = Duration.zero,
    this.buffered = Duration.zero,
    this.speed = 1.0,
    this.duration,
  });

  /// Whether it plays when it can: true through buffering, and at the end
  /// of a file until something pauses it.
  final bool playing;
  final SessionPhase phase;
  final Duration position;
  final Duration buffered;
  final double speed;

  /// Null until the engine learns it.
  final Duration? duration;

  static const idle = SessionState();
}

/// Whoever is in the session: the session's buttons call these.
abstract class SessionClient {
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);

  /// The notification's Stop, or the system letting the session go.
  Future<void> stop();
}

abstract class PlaybackSession {
  /// Puts [client] in the session, showing [tag]. Whoever was there is
  /// no longer controlled.
  void attach(SessionClient client, LockScreenTag tag);

  /// What [client] is doing now. Ignored from anyone but the one attached.
  void report(SessionClient client, SessionState state);

  /// [client] is done. Ignored from anyone but the one attached, so a
  /// player being let go cannot clear the session its successor took.
  void detach(SessionClient client);
}

/// Where there is no session (the web build, tests, a boot where the
/// service would not start): playback works, with nothing on the lock
/// screen.
class NoPlaybackSession implements PlaybackSession {
  const NoPlaybackSession();
  @override
  void attach(SessionClient client, LockScreenTag tag) {}
  @override
  void report(SessionClient client, SessionState state) {}
  @override
  void detach(SessionClient client) {}
}
