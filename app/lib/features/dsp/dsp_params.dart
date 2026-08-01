/// The offline DSP preprocess's pure math and laws (Campaign 6, ADR-0012):
/// the exact filter chain, the codec/bitrate an output extension picks,
/// the fail-closed sanity gate a processed file must pass before the
/// atomic promote, the time-saved counter's arithmetic, and the two
/// escape-hatch laws (per-feed opt-in over a household default; the
/// transcript-exclusivity eligibility rule). Nothing here touches a file,
/// a platform channel, or ffmpeg itself — see `dsp_encoder.dart` for the
/// boundary that does.
library;

/// Silence longer than this (seconds) gets trimmed; anything shorter is
/// left alone entirely — a deliberately conservative trigger chosen to
/// never bite into a natural pause between words or sentences.
const double kSilenceTriggerSeconds = 1.5;

/// How much of a triggered silence run is kept — never fully removed, so
/// a listener still hears a breath, never a hard cut.
const double kSilenceRetainSeconds = 0.5;

/// The volume floor (dBFS) below which audio counts as "silence" for
/// trimming purposes — conservative (very quiet) on purpose, so quiet
/// speech is never mistaken for silence and clipped.
const double kSilenceThresholdDb = -50;

/// The podcast-standard integrated loudness target (LUFS) — Apple
/// Podcasts/Spotify's own stated recommendation for spoken-word content.
const double kLoudnormTargetLufs = -16;

/// The true-peak ceiling (dBTP) loudnorm won't cross — headroom against
/// clipping on playback devices that don't do true-peak limiting of
/// their own.
const double kLoudnormTruePeakDbtp = -1.5;

/// Loudness range (LU) loudnorm targets — wide enough to keep a
/// speaker's natural dynamics rather than over-compressing them flat.
const double kLoudnormLra = 11;

/// A processed file must retain at least this fraction of the original's
/// duration to count as sane — anything shrunk further than this is
/// treated as a botched encode (garbage output), not real silence
/// trimming; this campaign's own conservative filter parameters make a
/// shrink beyond 90% implausible for genuine content.
const double kMinDspOutputFraction = 0.1;

/// The exact `-af` filter graph every DSP pass runs, built from the
/// constants above — the ADR quotes this string verbatim as "the chosen
/// filter parameters." `silenceremove` trims start-of-file AND
/// throughout (`stop_periods=-1`) uniformly; `loudnorm` runs single-pass
/// (no separate measure pass) to the podcast-standard target.
String dspFilterGraph() =>
    'silenceremove='
    'start_periods=1:start_duration=${_num(kSilenceTriggerSeconds)}:'
    'start_threshold=${_num(kSilenceThresholdDb)}dB:'
    'start_silence=${_num(kSilenceRetainSeconds)}:'
    'stop_periods=-1:stop_duration=${_num(kSilenceTriggerSeconds)}:'
    'stop_threshold=${_num(kSilenceThresholdDb)}dB:'
    'stop_silence=${_num(kSilenceRetainSeconds)},'
    'loudnorm=I=${_num(kLoudnormTargetLufs)}:'
    'TP=${_num(kLoudnormTruePeakDbtp)}:LRA=${_num(kLoudnormLra)}';

/// ffmpeg filter values as an integer literal reads (`-50`, not `-50.0`)
/// whenever a constant happens to be whole — cosmetic only, the numeric
/// value is unchanged either way.
String _num(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

/// The ffmpeg encoder for a downloaded file's extension — chosen so the
/// processed output stays playable through the SAME container/codec
/// family the original arrived in (never a silent format change).
/// Returns null for anything unrecognized; the caller's eligibility gate
/// treats that as "not eligible" rather than guessing at a codec.
String? dspCodecFor(String extension) => switch (extension.toLowerCase()) {
  '.mp3' => 'libmp3lame',
  '.m4a' || '.aac' || '.mp4' => 'aac',
  '.ogg' || '.oga' => 'libvorbis',
  '.opus' => 'libopus',
  '.wav' => 'pcm_s16le',
  _ => null,
};

/// A spoken-word-appropriate bitrate for [codec] — null for pcm, which
/// has no bitrate concept. 128k covers every lossy codec here except
/// opus, which reaches comparable quality at 96k (opus's own efficiency
/// advantage over mp3/aac/vorbis at spoken-word content).
String? dspBitrateFor(String codec) => switch (codec) {
  'libmp3lame' || 'aac' || 'libvorbis' => '128k',
  'libopus' => '96k',
  _ => null,
};

/// Milliseconds saved by processing — never negative. A processed file
/// that (rarely) comes out fractionally LONGER than the original, e.g.
/// from container/encoder overhead, saves zero rather than reporting a
/// negative number the lifetime counter would have to explain.
int timeSavedMs({
  required int originalDurationMs,
  required int processedDurationMs,
}) {
  final saved = originalDurationMs - processedDurationMs;
  return saved < 0 ? 0 : saved;
}

/// The fail-closed gate a processed file must pass BEFORE the atomic
/// promote — the model-store law: original kept until success is
/// actually verified, never merely assumed from a zero ffmpeg exit code.
bool dspOutputSane({
  required int originalDurationMs,
  required int processedDurationMs,
  required int outputSizeBytes,
}) {
  if (outputSizeBytes <= 0) return false;
  if (processedDurationMs <= 0) return false;
  if (processedDurationMs > originalDurationMs) return false;
  if (originalDurationMs <= 0) return false;
  return processedDurationMs >= originalDurationMs * kMinDspOutputFraction;
}

/// The transcript-exclusivity law (ADR-0012): process-or-align, never
/// both silently. An episode that already has a transcript, or has a
/// transcription job claimed against it (running, paused, or failed —
/// anything short of `done`), is not eligible for preprocessing. The
/// reverse is explicitly fine and enforced nowhere: an episode processed
/// FIRST transcribes against the processed file automatically, because
/// both paths read/write the exact same `audioFileFor` path.
bool dspEligible({
  required bool hasTranscript,
  required bool hasPendingOrFailedTranscribeJob,
}) => !hasTranscript && !hasPendingOrFailedTranscribeJob;

/// Where a DSP pass writes its working output before the coordinator's
/// atomic promote — same directory and extension as [audioPath] (so
/// ffmpeg's own extension-based format detection still picks the right
/// container/codec for [dspCodecFor]), with a `.dsppart` marker before
/// the extension so it can never collide with `AudioFetcher`'s own
/// `.part` download-resume convention on the same file.
String dspPartPathFor(String audioPath) {
  final dot = audioPath.lastIndexOf('.');
  if (dot < 0) return '$audioPath.dsppart';
  return '${audioPath.substring(0, dot)}.dsppart${audioPath.substring(dot)}';
}

/// Whether DSP applies to episodes of one feed: an explicit per-feed
/// override always wins over the household default; null defers to it.
/// Same escape-hatch shape as every other per-feed playback setting.
bool effectiveDspEnabled({
  required bool? feedOverride,
  required bool globalDefault,
}) => feedOverride ?? globalDefault;
