import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:trellis/features/player/just_audio_player.dart';
import 'package:trellis/features/player/playback_session.dart';

/// What the engine's own state becomes in the session (1.6.0). The
/// adapter only pipes streams; this is the one decision in it.
void main() {
  test('each engine state has its own phase', () {
    const phases = {
      ProcessingState.idle: SessionPhase.idle,
      ProcessingState.loading: SessionPhase.loading,
      ProcessingState.buffering: SessionPhase.buffering,
      ProcessingState.ready: SessionPhase.ready,
      ProcessingState.completed: SessionPhase.completed,
    };
    expect(phases.keys.toSet(), ProcessingState.values.toSet(),
        reason: 'a new engine state must be mapped, not guessed');
    for (final e in phases.entries) {
      expect(
          sessionStateOf(
                  playing: false,
                  processingState: e.key,
                  position: Duration.zero,
                  buffered: Duration.zero,
                  speed: 1,
                  duration: null)
              .phase,
          e.value,
          reason: '${e.key}');
    }
  });

  test('playing, place, speed and length pass through as the engine has '
      'them, at the end of a file too', () {
    final s = sessionStateOf(
        playing: true,
        processingState: ProcessingState.completed,
        position: const Duration(minutes: 5),
        buffered: const Duration(minutes: 5),
        speed: 2,
        duration: const Duration(minutes: 5));

    expect(s.playing, isTrue,
        reason: 'the engine still means to play; the app pauses it or '
            'loads what follows');
    expect(s.phase, SessionPhase.completed);
    expect(s.position, const Duration(minutes: 5));
    expect(s.buffered, const Duration(minutes: 5));
    expect(s.speed, 2);
    expect(s.duration, const Duration(minutes: 5));
  });
}
