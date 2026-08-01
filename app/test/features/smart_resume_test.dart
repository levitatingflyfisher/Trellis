import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/player/smart_resume.dart';

/// Resuming a paused podcast episode rewinds by a small amount scaled to how
/// long it was paused: barely lost the thread (<1min) needs almost nothing
/// back; a typical interruption (<1h) needs a few seconds; a real return
/// needs a fuller re-anchor. Pure function — no player, no clock, just the
/// three brackets and their boundaries.
void main() {
  group('smartResumeRewind', () {
    test('under a minute rewinds 2s', () {
      expect(smartResumeRewind(Duration.zero), const Duration(seconds: 2));
      expect(smartResumeRewind(const Duration(seconds: 59)),
          const Duration(seconds: 2));
    });

    test('at exactly a minute and under an hour rewinds 5s', () {
      expect(smartResumeRewind(const Duration(minutes: 1)),
          const Duration(seconds: 5));
      expect(
          smartResumeRewind(
              const Duration(hours: 1) - const Duration(seconds: 1)),
          const Duration(seconds: 5));
    });

    test('at exactly an hour or beyond rewinds 10s', () {
      expect(smartResumeRewind(const Duration(hours: 1)),
          const Duration(seconds: 10));
      expect(smartResumeRewind(const Duration(days: 3)),
          const Duration(seconds: 10));
    });
  });
}
