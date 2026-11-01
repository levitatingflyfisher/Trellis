/// How clearly a made episode is spoken (the founding request's
/// follow-up: "Bonus points if I can choose how much they enunciate,
/// ranging from totally colloquial street speech to as crisp and clean as
/// possible to make it easy for a beginner to parse").
///
/// What a saved voice can honestly vary, read from each engine:
///  * how long a sentence takes ([SpeechPace.rate]): Kokoro (Chinese)
///    speaks slower, and the phone's voice takes Android's speech rate.
///    Pocket TTS (the other seven languages) has no speed input: its
///    words keep their own pace and a pause in proportion follows each
///    sentence instead (`pocketPauseSamples`). So the help lines promise
///    a slower episode overall, never slower words;
///  * the pause after each sentence and each paragraph, which Trellis
///    writes itself between the sentences it saves;
///  * on Pocket TTS only, more flow steps per frame (four instead of one):
///    the engine's own quality setting, more work on each sound.
///
/// The street-speech end of the dial is not here: every engine reads the
/// words they are given in one register, and none can make speech
/// more casual. That would take other words (a colloquial translation)
/// and a voice trained on casual speech; see the founding request page.
library;

import '../../db/database.dart';
import '../reader/speech/speech_engine.dart';

/// The device setting: how clearly a made episode is spoken.
const listenClearnessKey = 'listen_clearness';

enum ListenClearness {
  natural(
    label: 'Natural',
    help: 'The voice’s own pace, with short pauses.',
    pace: SpeechPace.natural,
    sentenceGapMs: 250,
    segmentGapMs: 450,
    spokenPhrase: 'spoken at a natural pace',
  ),
  clear(
    label: 'Clear',
    help: 'A little slower overall, with a longer pause after each sentence.',
    pace: SpeechPace(rate: 0.9, careful: true),
    sentenceGapMs: 500,
    segmentGapMs: 800,
    spokenPhrase: 'spoken clearly',
  ),
  slow(
    label: 'Slow and clear',
    help: 'Slower overall, with a long pause after each sentence.',
    pace: SpeechPace(rate: 0.75, careful: true),
    sentenceGapMs: 800,
    segmentGapMs: 1200,
    spokenPhrase: 'spoken slowly and clearly',
  ),
  verySlow(
    label: 'Very slow',
    help: 'The slowest, with the longest pauses. For a first try at a '
        'language.',
    pace: SpeechPace(rate: 0.6, careful: true),
    sentenceGapMs: 1200,
    segmentGapMs: 1800,
    spokenPhrase: 'spoken very slowly and clearly',
  );

  const ListenClearness({
    required this.label,
    required this.help,
    required this.pace,
    required this.sentenceGapMs,
    required this.segmentGapMs,
    required this.spokenPhrase,
  });

  /// Its name on screen.
  final String label;

  /// One line under the name, saying what it does.
  final String help;

  /// How the voice is asked to say each sentence.
  final SpeechPace pace;

  /// The silence after a sentence, and after the last of a paragraph.
  final int sentenceGapMs;
  final int segmentGapMs;

  /// How the saved episode's page says it was spoken.
  final String spokenPhrase;

  /// The step stored as [name]; Natural for anything else, which is how
  /// every episode was made before the setting existed.
  static ListenClearness parse(String? name) {
    for (final c in values) {
      if (c.name == name) return c;
    }
    return natural;
  }
}

/// The step chosen on this device; Natural until one is.
Future<ListenClearness> readListenClearness(AppDatabase db) async =>
    ListenClearness.parse(await db.deviceSettingsDao.read(listenClearnessKey));

Future<void> writeListenClearness(AppDatabase db, ListenClearness c) =>
    db.deviceSettingsDao.write(listenClearnessKey, c.name);
