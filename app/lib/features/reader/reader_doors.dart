import 'package:flutter/material.dart';

import '../../db/database.dart' hide Alignment;
import '../../services/device_services.dart';
import '../intake/paste_intake.dart' show epochDayUtcNow;
import '../player/karaoke_screen.dart';
import '../player/player_controller.dart';
import 'reader_logic.dart' show shouldOfferRecap;
import 'reader_screen.dart';
import 'speech/speech_engine.dart';
import 'speech/speech_temp_files.dart';
import 'translation/marian_engine.dart';

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
    this.resolveTranslator,
    this.availableTranslationTargets,
  });

  final TtsSpeaker? tts;
  final bool localMlAvailable;
  final Future<SynthesisSpeechEngine?> Function({String? lang})?
      resolveSpeechEngine;
  final Future<String?> Function(String word)? lookupDefinition;
  final SpeechTempFiles Function()? createSpeechTempFiles;
  final PlayerController? player;
  final Future<MarianTranslator?> Function(
      {required String sourceLang, required String targetLang})?
      resolveTranslator;
  final Future<List<String>> Function({required String sourceLang})?
      availableTranslationTargets;

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
    await Navigator.of(context).push(MaterialPageRoute<void>(
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
          resolveTranslator: resolveTranslator,
          availableTranslationTargets: availableTranslationTargets,
          offerRecap: offerRecap,
          startSegmentIdx: startSegmentIdx),
    ));
  }

  /// Opens [work]'s transcript without playing it: a podcast is readable
  /// as well as playable. Needs [player], which a tap on a line plays
  /// from, so a screen offers Read only when [canOpenTranscript].
  bool get canOpenTranscript => player != null;

  Future<void> openTranscript(BuildContext context,
      {required AppDatabase db, required Work work}) async {
    final p = player;
    if (p == null) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => KaraokeScreen(
          db: db,
          controller: p,
          work: work,
          tts: tts,
          resolveSpeechEngine: resolveSpeechEngine,
          createSpeechTempFiles: createSpeechTempFiles,
          resolveTranslator: resolveTranslator,
          availableTranslationTargets: availableTranslationTargets),
    ));
  }
}
