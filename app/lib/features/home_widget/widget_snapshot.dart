/// What the home-screen widget (1.5.5) shows, as Dart writes it for the
/// Kotlin provider to read (android/.../TrellisWidget.kt). The provider may
/// run with the app's process freshly started and no Dart at all, so this
/// is everything it needs, and nothing it would have to look up.
library;

class AudioCard {
  final int workId;
  final String title;

  /// The podcast's name; null for an audiobook, which has no show.
  final String? show;

  /// A local file the provider decodes itself; null when none is on disk.
  /// Never a URL: the widget fetches nothing.
  final String? artPath;
  final int positionMs;
  final int? durationMs;
  final bool playing;

  /// Whether the player holds this work's audio now. Only then may a
  /// widget tap play it without the app's screen: loading a stream first
  /// can outlast the moment Android lets a background app start playback.
  final bool loaded;

  const AudioCard({
    required this.workId,
    required this.title,
    this.show,
    this.artPath,
    required this.positionMs,
    this.durationMs,
    required this.playing,
    this.loaded = false,
  });

  Map<String, Object?> toJson() => {
    'workId': workId,
    'title': title,
    'show': show,
    'art': artPath,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'playing': playing,
    'loaded': loaded,
  };
}

class ReadingCard {
  final int workId;
  final String title;

  /// How far reading reached, 0 to 1, as the library's bars count it.
  final double progress;

  const ReadingCard({
    required this.workId,
    required this.title,
    required this.progress,
  });

  Map<String, Object?> toJson() => {
    'workId': workId,
    'title': title,
    'progress': progress,
  };
}

class WidgetSnapshot {
  /// The reader whose listening and reading these are; the widget's taps
  /// carry it back so another reader's shell ignores them.
  final int profileId;
  final AudioCard? audio;
  final ReadingCard? reading;

  const WidgetSnapshot({required this.profileId, this.audio, this.reading});

  Map<String, Object?> toJson() => {
    'v': 1,
    'profileId': profileId,
    'audio': audio?.toJson(),
    'reading': reading?.toJson(),
  };
}
