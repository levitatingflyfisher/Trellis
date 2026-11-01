import 'package:comms_core/comms_core.dart' show HttpFetcher;
import 'package:flutter/material.dart';

import '../../bootstrap/bootstrap.dart' show playbackSession;
import '../../db/database.dart' hide Alignment;
import '../../services/device_services.dart';
import '../intake/paste_intake.dart' show epochDayUtcNow;
import '../player/player_controller.dart';
import 'reader_logic.dart' show shouldOfferRecap;
import 'reader_screen.dart';
import 'speech/speech_engine.dart';
import 'speech/speech_temp_files.dart';
import 'translation/translation_service.dart';

/// The seams a reader needs, carried as one value so every screen that
/// opens a book opens it the same way: the Library and the Subscriptions
/// page's Books shelf must not drift apart on voice, recap or translation.
class ReaderDoors {
  const ReaderDoors({
    this.tts,
    this.localMlAvailable = true,
    this.resolveSpeechEngine,
    this.lookupDefinition,
    this.createSpeechTempFiles,
    this.player,
    this.translation,
    this.fetcher,
  });

  final TtsSpeaker? tts;
  final bool localMlAvailable;
  final Future<SynthesisSpeechEngine?> Function({String? lang})?
      resolveSpeechEngine;
  final Future<String?> Function(String word)? lookupDefinition;
  final SpeechTempFiles Function()? createSpeechTempFiles;
  final PlayerController? player;
  /// Translation for the readers this opens (1.5.5); null hides
  /// Translate. See [TranslationService].
  final TranslationService? translation;

  /// Fetches a page a link points to, to keep a copy (frozen
  /// references); null offers no keeping.
  final HttpFetcher? fetcher;

  /// Pushes the reader for [work] and completes when it pops. The voice
  /// and the recap offer are settled before the push (ADR-0006): the
  /// reader's first frame already needs both.
  Future<void> open(
    BuildContext context, {
    required AppDatabase db,
    required int profileId,
    required Work work,
    required Position? position,
    required int segmentCount,
    int? startSegmentIdx,
    bool startSpeaking = false,
    bool speakTranslation = false,
    String? layerLang,
    bool openTranslatePicker = false,
    bool openOnPage = false,
    ReaderNote? note,
  }) async {
    final resolver = resolveSpeechEngine;
    final hasVoice =
        resolver == null ? false : await resolver(lang: work.lang) != null;
    if (!context.mounted) return;
    final offerRecap = shouldOfferRecap(
        lastTouchedEpochDay: position == null
            ? null
            : position.updatedAtMs ~/ Duration.millisecondsPerDay,
        todayEpochDay: epochDayUtcNow(),
        progress: segmentCount == 0
            ? 0
            : (position?.segmentIdx ?? 0) / segmentCount);
    // The reader takes the whole screen (1.5.8): it opens on the app's
    // Navigator, over the tabs and their bars, wherever it is opened from.
    await Navigator.of(context, rootNavigator: true)
        .push(MaterialPageRoute<void>(
      builder: (_) => ReaderScreen(
          db: db,
          profileId: profileId,
          work: work,
          tts: tts,
          offerNeuralVoice: localMlAvailable && !hasVoice,
          resolveSpeechEngine: resolveSpeechEngine,
          lookupDefinition: lookupDefinition,
          createSpeechTempFiles: createSpeechTempFiles,
          player: player,
          translation: translation,
          offerRecap: offerRecap,
          startSegmentIdx: startSegmentIdx,
          startSpeaking: startSpeaking,
          speakTranslation: speakTranslation,
          layerLang: layerLang,
          openTranslatePicker: openTranslatePicker,
          openOnPage: openOnPage,
          note: note,
          fetcher: fetcher,
          // The app's one media session (nothing in tests and on the web):
          // every door opens a reader that can read on behind the screen.
          session: playbackSession),
    ));
  }

  /// Whether a transcript can be read here: Read on a transcript opens
  /// the reader with [player], which a tapped word plays from.
  bool get canOpenTranscript => player != null;
}
