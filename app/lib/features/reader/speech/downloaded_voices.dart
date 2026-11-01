/// Trellis's own voices, one per language (owner, 13 Nov, board-0211):
/// every downloaded voice behind one [SynthesisSpeechEngine], each
/// sentence said by the voice for its language. A run that reads German
/// and Chinese uses the German voice for one and the Chinese voice for
/// the other, in the one gapless queue the app owns.
///
/// Each voice opens on its first sentence and stays open until
/// [dispose]: the same residency law every engine under it keeps. A
/// voice registered for several languages is one engine, opened once.
library;

import 'package:ml_runtime/ml_runtime.dart' show ModelSpec, baseLangTag;

import 'speech_engine.dart';

/// No downloaded voice speaks the sentence's language: a calm refusal,
/// never another language's voice reading it.
class DownloadedVoiceLangException implements Exception {
  final String message;
  const DownloadedVoiceLangException(this.message);
  @override
  String toString() => message;
}

class DownloadedVoices implements SynthesisSpeechEngine {
  /// Which voice (by model id) speaks each bare language tag.
  final Map<String, String> voiceByLang;

  /// Opens the voice with this id. Called at most once per voice while
  /// it succeeds; a failed open is tried again on the next sentence.
  final Future<SynthesisSpeechEngine> Function(String id) open;

  final Map<String, Future<SynthesisSpeechEngine>> _opened = {};

  DownloadedVoices({required this.voiceByLang, required this.open});

  @override
  bool get canPause => true;

  @override
  Set<String> get speaks => voiceByLang.keys.toSet();

  @override
  Future<SynthResult> synthesize(String sentence,
      {String? lang, SpeechPace pace = SpeechPace.natural}) {
    final named = lang == null ? '' : baseLangTag(lang);
    final resolved = named.isNotEmpty
        ? named
        : voiceByLang.containsKey('en') || voiceByLang.length != 1
            ? 'en'
            : voiceByLang.keys.single;
    final id = voiceByLang[resolved];
    if (id == null) {
      throw DownloadedVoiceLangException(
          'No downloaded voice speaks “$resolved”. Try the phone’s voice.');
    }
    return _engine(id)
        .then((e) => e.synthesize(sentence, lang: resolved, pace: pace));
  }

  Future<SynthesisSpeechEngine> _engine(String id) {
    final opening = _opened[id] ??= open(id);
    // A failed open is forgotten, so the next sentence tries again.
    opening.then((_) {}, onError: (_) {
      if (identical(_opened[id], opening)) _opened.remove(id);
    });
    return opening;
  }

  @override
  Future<void> dispose() async {
    final all = _opened.values.toList();
    _opened.clear();
    for (final f in all) {
      try {
        await (await f).dispose();
      } catch (_) {
        // It never opened; nothing to release.
      }
    }
  }
}

/// A downloaded voice's plain name, for an episode's page: its engine's
/// own name.
String downloadedVoiceName(ModelSpec spec) {
  if (spec.kokoroLayout != null) return 'Kokoro';
  if (spec.pocketLayout != null) return 'Pocket TTS';
  return spec.id;
}
