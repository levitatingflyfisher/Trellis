import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/dsp/dsp_params.dart';

/// The pure math and laws behind the offline DSP preprocess (Campaign 6,
/// ADR-0012) — no ffmpeg, no file, no platform channel reachable from any
/// test here. The filter graph string these constants build IS the
/// documented, chosen parameter set the ADR reports.
void main() {
  group('dspFilterGraph', () {
    test('builds the exact silenceremove+loudnorm chain, in order', () {
      expect(
        dspFilterGraph(),
        'silenceremove=start_periods=1:start_duration=1.5:'
        'start_threshold=-50dB:start_silence=0.5:stop_periods=-1:'
        'stop_duration=1.5:stop_threshold=-50dB:stop_silence=0.5,'
        'loudnorm=I=-16:TP=-1.5:LRA=11',
      );
    });
  });

  group('dspCodecFor', () {
    test('mp3 -> libmp3lame', () {
      expect(dspCodecFor('.mp3'), 'libmp3lame');
      expect(dspCodecFor('.MP3'), 'libmp3lame', reason: 'case-insensitive');
    });
    test('m4a/aac/mp4 -> the native aac encoder', () {
      expect(dspCodecFor('.m4a'), 'aac');
      expect(dspCodecFor('.aac'), 'aac');
      expect(dspCodecFor('.mp4'), 'aac');
    });
    test('ogg/oga -> libvorbis', () {
      expect(dspCodecFor('.ogg'), 'libvorbis');
      expect(dspCodecFor('.oga'), 'libvorbis');
    });
    test('opus -> libopus', () {
      expect(dspCodecFor('.opus'), 'libopus');
    });
    test('wav -> pcm_s16le (no bitrate concept)', () {
      expect(dspCodecFor('.wav'), 'pcm_s16le');
    });
    test('an unrecognized extension refuses rather than guesses', () {
      expect(dspCodecFor('.weird'), isNull);
      expect(dspCodecFor(''), isNull);
    });
  });

  group('dspBitrateFor', () {
    test('every lossy codec gets a spoken-word bitrate; pcm gets none', () {
      expect(dspBitrateFor('libmp3lame'), '128k');
      expect(dspBitrateFor('aac'), '128k');
      expect(dspBitrateFor('libvorbis'), '128k');
      expect(dspBitrateFor('libopus'), '96k');
      expect(dspBitrateFor('pcm_s16le'), isNull);
    });
  });

  group('timeSavedMs', () {
    test('the normal case: original minus processed', () {
      expect(
        timeSavedMs(originalDurationMs: 600000, processedDurationMs: 540000),
        60000,
      );
    });
    test('equal durations save nothing', () {
      expect(
        timeSavedMs(originalDurationMs: 600000, processedDurationMs: 600000),
        0,
      );
    });
    test('never negative — a processed file that came out LONGER (encoder '
        'padding) saves zero, not a negative number', () {
      expect(
        timeSavedMs(originalDurationMs: 600000, processedDurationMs: 600050),
        0,
      );
    });
  });

  group('dspOutputSane — fail-closed before the atomic promote', () {
    test('a normal, modestly-shrunk output is sane', () {
      expect(
        dspOutputSane(
          originalDurationMs: 600000,
          processedDurationMs: 540000,
          outputSizeBytes: 8000000,
        ),
        isTrue,
      );
    });

    test('zero duration is never sane (a garbage/empty encode)', () {
      expect(
        dspOutputSane(
          originalDurationMs: 600000,
          processedDurationMs: 0,
          outputSizeBytes: 8000000,
        ),
        isFalse,
      );
    });

    test('zero size is never sane, even with a plausible duration', () {
      expect(
        dspOutputSane(
          originalDurationMs: 600000,
          processedDurationMs: 540000,
          outputSizeBytes: 0,
        ),
        isFalse,
      );
    });

    test('processed LONGER than original is never sane — silenceremove '
        'only ever shrinks', () {
      expect(
        dspOutputSane(
          originalDurationMs: 600000,
          processedDurationMs: 700000,
          outputSizeBytes: 8000000,
        ),
        isFalse,
      );
    });

    test('shrinking below the plausible floor (implausibly aggressive '
        'silence trimming) is rejected as likely-garbage output', () {
      expect(
        dspOutputSane(
          originalDurationMs: 600000,
          processedDurationMs: 30000, // 5% of original
          outputSizeBytes: 8000000,
        ),
        isFalse,
      );
    });

    test('right at the floor is still sane (boundary is inclusive)', () {
      expect(
        dspOutputSane(
          originalDurationMs: 600000,
          processedDurationMs: 60000, // exactly 10%
          outputSizeBytes: 8000000,
        ),
        isTrue,
      );
    });
  });

  group('dspEligible — the transcript-exclusivity law', () {
    test('no transcript, no pending/failed transcribe job: eligible', () {
      expect(
        dspEligible(
          hasTranscript: false,
          hasPendingOrFailedTranscribeJob: false,
        ),
        isTrue,
      );
    });
    test('a transcript already exists: never eligible', () {
      expect(
        dspEligible(
          hasTranscript: true,
          hasPendingOrFailedTranscribeJob: false,
        ),
        isFalse,
      );
    });
    test('a transcribe job is pending or failed (not yet a transcript, but '
        'claimed): never eligible either — process-or-align, never both '
        'silently', () {
      expect(
        dspEligible(
          hasTranscript: false,
          hasPendingOrFailedTranscribeJob: true,
        ),
        isFalse,
      );
    });
    test('both true: still never eligible', () {
      expect(
        dspEligible(hasTranscript: true, hasPendingOrFailedTranscribeJob: true),
        isFalse,
      );
    });
  });

  group('dspPartPathFor', () {
    test('inserts a .dsppart marker before the extension, same directory', () {
      expect(
        dspPartPathFor('/support/audio/42.mp3'),
        '/support/audio/42.dsppart.mp3',
      );
    });
    test('an extensionless path gets a bare suffix', () {
      expect(dspPartPathFor('/support/audio/42'), '/support/audio/42.dsppart');
    });
    test('never collides with AudioFetcher\'s own .part convention', () {
      final part = '/support/audio/42.mp3.part';
      expect(dspPartPathFor('/support/audio/42.mp3'), isNot(part));
    });
  });

  group('effectiveDspEnabled — the per-feed/global escape hatch', () {
    test('no feed override: defers to the household default', () {
      expect(
        effectiveDspEnabled(feedOverride: null, globalDefault: true),
        isTrue,
      );
      expect(
        effectiveDspEnabled(feedOverride: null, globalDefault: false),
        isFalse,
      );
    });
    test('an explicit feed override always wins, either direction', () {
      expect(
        effectiveDspEnabled(feedOverride: true, globalDefault: false),
        isTrue,
      );
      expect(
        effectiveDspEnabled(feedOverride: false, globalDefault: true),
        isFalse,
      );
    });
  });
}
