/// The phone's own voice as a voice that can be SAVED (board-0126, owner:
/// "I'd like it to work for eg russian, japanese, german, not just
/// spanish"). Read aloud already speaks with it, a sentence at a time,
/// straight to the speaker. Saving needs the sound itself, which Android
/// hands over only one way: `TextToSpeech.synthesizeToFile`, one WAV file
/// per sentence.
///
/// That runs through the app's own channel (MainActivity's PhoneVoice.kt),
/// not flutter_tts's `synthesizeToFile`. In the pinned flutter_tts (4.2.5)
/// an engine error, or a sentence the engine refuses to queue, never
/// answers the awaited call, so one bad sentence would hang the job
/// forever; and it shares one engine, voice and language with Read aloud,
/// so either could change the other's mid-sentence.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../services/device_services.dart' show SystemVoice;
import 'speech_engine.dart';
import 'wav.dart';

/// What the phone's text-to-speech can say, as it said it last.
class PhoneVoices {
  /// The engine's own name as Android shows it ("Speech Services by
  /// Google"), or null when it gives none.
  final String? engine;

  /// The installed voices: downloaded, or spoken over the internet.
  final List<SystemVoice> voices;

  const PhoneVoices({this.engine, this.voices = const []});

  /// The bare languages there is a voice for.
  Set<String> get langs => {
        for (final v in voices)
          if (v.lang.isNotEmpty) v.lang
      };

  @override
  bool operator ==(Object other) =>
      other is PhoneVoices &&
      other.engine == engine &&
      listEquals(other.voices, voices);

  @override
  int get hashCode => Object.hash(engine, Object.hashAll(voices));
}

/// The platform's half. Tests hand in a fake.
abstract interface class PhoneSpeechSaver {
  /// The installed voices, or null when the engine can't be reached.
  Future<PhoneVoices?> voices();

  /// Writes [text] said in [lang] to [path] as a WAV file, with the voice
  /// named [voice] when it is given and still installed. Completes when
  /// the file is whole; throws when the engine refused or failed.
  Future<void> sayToFile(String text,
      {required String lang, String? voice, required String path});

  /// Opens Android's text-to-speech settings, where a voice is added.
  /// False when this phone has no such page.
  Future<bool> openSettings();
}

/// The phone's voices, asked once and kept for the session: the one-tap
/// list asks on every row. Asked again when the app comes back to the
/// front ([refresh]), since a voice is installed in Android's settings,
/// outside the app.
class PhoneVoiceCache extends ChangeNotifier {
  PhoneVoiceCache(this.saver,
      {PhoneVoices? known, this.timeout = const Duration(seconds: 5)})
      : _known = known;

  /// Null where the phone's voice cannot be saved (the web, tests).
  final PhoneSpeechSaver? saver;

  /// How long an answer is waited for: an engine still binding after an
  /// update can take a while, and the list must not wait on it forever.
  final Duration timeout;

  PhoneVoices? _known;
  Future<void>? _asking;

  /// The installed voices as last heard; empty before the first answer.
  List<SystemVoice> get voices => _known?.voices ?? const [];
  Set<String> get langs => _known?.langs ?? const {};
  String? get engine => _known?.engine;

  /// Asks the phone again. An engine that doesn't answer leaves what was
  /// known as it was. Listeners hear only of a real change.
  Future<void> refresh() => _asking ??= _ask().whenComplete(() {
        _asking = null;
      });

  Future<void> _ask() async {
    final s = saver;
    if (s == null) return;
    final pending = s.voices();
    PhoneVoices? heard;
    try {
      heard = await pending.timeout(timeout);
    } on TimeoutException {
      // Stop waiting, but keep the answer when it comes: after a cold
      // start the engine can take longer than [timeout] to bind.
      unawaited(pending.then(_take, onError: (Object _) {}));
      return;
    } catch (_) {
      heard = null;
    }
    _take(heard);
  }

  void _take(PhoneVoices? heard) {
    if (heard == null || heard == _known) return;
    _known = heard;
    notifyListeners();
  }
}

/// The name a saved episode gives the phone's voice: plain, with the
/// engine's own name where Android gives one.
String phoneVoiceName(String? engine) => engine == null || engine.isEmpty
    ? 'the phone’s own voice'
    : 'the phone’s own voice, $engine';

/// Says one sentence with the phone's voice and hands back its sound, as
/// the downloaded voice does: through a WAV file in [dir] that is gone
/// again when this returns.
Future<SynthResult> sayWithPhone(PhoneSpeechSaver saver, String text,
    {required String lang, String? voice, required Directory dir}) async {
  await dir.create(recursive: true);
  final file = File('${dir.path}/phone-${DateTime.now().microsecondsSinceEpoch}'
      '-${_next++}.wav');
  try {
    await saver.sayToFile(text, lang: lang, voice: voice, path: file.path);
    final read = readWav(await file.readAsBytes());
    if (read == null) {
      throw StateError('the phone’s voice wrote audio this can’t read');
    }
    return SynthResult(samples: read.samples, sampleRate: read.sampleRate);
  } finally {
    if (file.existsSync()) file.deleteSync();
  }
}

var _next = 0;

/// The real phone: the app's own channel to Android's TextToSpeech.
class MethodChannelPhoneSpeechSaver implements PhoneSpeechSaver {
  MethodChannelPhoneSpeechSaver(
      [this._channel = const MethodChannel('com.openhearth.trellis/phone_voice')]);

  final MethodChannel _channel;

  @override
  Future<PhoneVoices?> voices() async {
    final raw = await _channel.invokeMethod<Object?>('voices');
    if (raw is! Map) return null;
    final list = raw['voices'];
    if (list is! List) return null;
    final engine = raw['engine'];
    return PhoneVoices(
      engine: engine is String && engine.isNotEmpty ? engine : null,
      voices: [
        for (final v in list)
          if (v is Map && v['name'] is String && v['locale'] is String)
            SystemVoice(
                name: v['name'] as String,
                locale: v['locale'] as String,
                needsInternet: v['network'] == true),
      ],
    );
  }

  @override
  Future<void> sayToFile(String text,
      {required String lang, String? voice, required String path}) async {
    final ok = await _channel.invokeMethod<bool>('sayToFile',
        {'text': text, 'lang': lang, 'voice': voice, 'path': path});
    if (ok != true) throw StateError('the phone’s voice wrote nothing');
  }

  @override
  Future<bool> openSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openSettings') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
