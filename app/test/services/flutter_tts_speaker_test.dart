import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/services/device_services.dart';

/// FlutterTtsSpeaker against flutter_tts 4.2.5's Android channel answers:
/// setLanguage answers 0 when the engine has no voice for the language
/// (and would read on with whatever voice it has), setVoice 0 for a
/// voice that is gone, and getVoices lists voices not yet downloaded
/// with a "notInstalled" feature.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_tts');
  late List<MethodCall> calls;
  late Set<String> languages;
  late Set<String> voiceNames;
  late Object? voiceList;
  late Completer<Object?>? pendingSpeak;
  late Object? Function(String name)? setVoiceAnswer;
  late List<Object?> voiceAnswers;

  setUp(() {
    calls = [];
    languages = {'en'};
    voiceNames = {};
    voiceList = null;
    pendingSpeak = null;
    setVoiceAnswer = null;
    voiceAnswers = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'setLanguage':
          return languages.contains(call.arguments) ? 1 : 0;
        case 'setVoice':
          final name = (call.arguments as Map)['name'] as String;
          if (setVoiceAnswer != null) return setVoiceAnswer!(name);
          return voiceNames.contains(name) ? 1 : 0;
        case 'getVoices':
          if (voiceAnswers.isNotEmpty) return voiceAnswers.removeAt(0);
          return voiceList;
        case 'speak':
          // Android with awaitSpeakCompletion: the answer waits for
          // onDone (or stop); an engine error only sends speak.onError.
          return pendingSpeak?.future ?? 1;
        default:
          return 1;
      }
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  List<String> spoken() => [
        for (final c in calls)
          // Android sends {text, focus}; every other platform the text.
          if (c.method == 'speak')
            '${c.arguments is Map ? (c.arguments as Map)['text'] : c.arguments}'
      ];

  test('a language the engine has no voice for is refused, never read '
      'with another voice', () async {
    final speaker = FlutterTtsSpeaker();
    await speaker.speak('Hello.', lang: 'en');
    await expectLater(speaker.speak('Привет.', lang: 'ru'),
        throwsA(isA<TtsNoVoiceException>()));
    expect(spoken(), ['Hello.']);
  });

  test('a picked voice is set by name; one that is gone falls back to the '
      'language\'s default', () async {
    voiceNames = {'ru-ru-x-rud-local'};
    languages = {'en', 'ru'};
    final speaker = FlutterTtsSpeaker();
    await speaker.speak('Привет.',
        lang: 'ru',
        voice: const SystemVoice(name: 'ru-ru-x-rud-local', locale: 'ru-RU'));
    expect(calls.where((c) => c.method == 'setVoice'), hasLength(1));
    expect(calls.where((c) => c.method == 'setLanguage'), isEmpty);

    await speaker.speak('Пока.',
        lang: 'ru',
        voice: const SystemVoice(name: 'ru-ru-x-gone', locale: 'ru-RU'));
    expect(calls.last.method, 'speak');
    expect(calls.where((c) => c.method == 'setLanguage').single.arguments,
        'ru');
    // Back to English: its own default voice, set again.
    await speaker.speak('Hello.', lang: 'en');
    expect(calls.where((c) => c.method == 'setLanguage').last.arguments, 'en');
    expect(spoken(), ['Привет.', 'Пока.', 'Hello.']);
  });

  /// What the Android plugin sends when the engine fails an utterance
  /// (UtteranceProgressListener.onError): speak.onError, and nothing for
  /// the pending speak call.
  Future<void> engineError(String message) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
            channel.name,
            channel.codec
                .encodeMethodCall(MethodCall('speak.onError', message)),
            (_) {});
  }

  test('an engine error ends the utterance with an error instead of '
      'leaving it waiting forever', () async {
    languages = {'en', 'ru'};
    pendingSpeak = Completer<Object?>();
    final speaker = FlutterTtsSpeaker();
    final spoken = speaker.speak('Привет.', lang: 'ru');
    await pumpEventQueue();
    expect(calls.last.method, 'speak');

    final failed = expectLater(spoken, throwsA(isA<TtsSpeakException>()));
    await engineError('Error from TextToSpeech (speak) - -6');
    await failed;

    // The next sentence speaks normally.
    pendingSpeak = null;
    await speaker.speak('Пока.', lang: 'ru');
  });

  test('an error after stop changes nothing: a stopped utterance has '
      'completed', () async {
    pendingSpeak = Completer<Object?>();
    final speaker = FlutterTtsSpeaker();
    final spoken = speaker.speak('Hello.', lang: 'en');
    await pumpEventQueue();
    final done = expectLater(spoken, completes);
    // The web: stop answers nothing for the pending speak, and
    // speechSynthesis reports the cancel as an error.
    await speaker.stop();
    await engineError('interrupted');
    await done;
  });

  test('language and voice are set before every sentence, so an engine '
      'that reconnected (back on its default language) never reads on '
      'with the wrong one', () async {
    languages = {'en', 'ru'};
    voiceNames = {'ru-ru-x-rud-local'};
    final speaker = FlutterTtsSpeaker();
    const voice = SystemVoice(name: 'ru-ru-x-rud-local', locale: 'ru-RU');
    await speaker.speak('Привет.', lang: 'ru');
    await speaker.speak('Пока.', lang: 'ru');
    await speaker.speak('Да.', lang: 'ru', voice: voice);
    await speaker.speak('Нет.', lang: 'ru', voice: voice);
    expect(calls.where((c) => c.method == 'setLanguage'), hasLength(2));
    expect(calls.where((c) => c.method == 'setVoice'), hasLength(2));
  });

  test('a voice counts as set only when the engine answers 1 (the web '
      'answers null whether or not it found the voice)', () async {
    languages = {'ru'};
    setVoiceAnswer = (_) => null;
    final speaker = FlutterTtsSpeaker();
    await speaker.speak('Привет.',
        lang: 'ru',
        voice: const SystemVoice(name: 'Google русский', locale: 'ru-RU'));
    expect(calls.where((c) => c.method == 'setLanguage').single.arguments,
        'ru');
  });

  group('a browser lists no voices until it has loaded them', () {
    const ru = {'name': 'Google русский', 'locale': 'ru-RU'};

    test('an empty list is asked again, briefly, before it is believed',
        () async {
      voiceAnswers = [<Object?>[], <Object?>[], [ru]];
      final voices = await FlutterTtsSpeaker(
              waitForVoices: true, voicePoll: Duration.zero)
          .voices();
      expect(voices, const [SystemVoice(name: 'Google русский', locale: 'ru-RU')]);
      expect(calls.where((c) => c.method == 'getVoices'), hasLength(3));
    });

    test('still empty after the wait: no voices, so nothing is read with '
        'a voice for another language', () async {
      voiceList = <Object?>[];
      final voices = await FlutterTtsSpeaker(
              waitForVoices: true, voicePoll: Duration.zero)
          .voices();
      expect(voices, isEmpty);
      expect(calls.where((c) => c.method == 'getVoices').length,
          greaterThan(1));
    });

    test('a phone believes its first answer', () async {
      voiceList = <Object?>[];
      expect(await FlutterTtsSpeaker().voices(), isEmpty);
      expect(calls.where((c) => c.method == 'getVoices'), hasLength(1));
    });
  });

  test('voices lists the installed ones only', () async {
    voiceList = [
      {
        'name': 'ru-ru-x-ruc-local',
        'locale': 'ru-RU',
        'network_required': '0',
        'features': 'networkTimeoutMs\tnetworkRetriesCount',
      },
      {
        'name': 'ru-ru-x-ruc-network',
        'locale': 'ru-RU',
        'network_required': '1',
        'features': '',
      },
      {
        'name': 'de-de-x-deb-local',
        'locale': 'de-DE',
        'network_required': '0',
        'features': 'notInstalled',
      },
    ];
    final voices = await FlutterTtsSpeaker().voices();
    expect(voices, const [
      SystemVoice(name: 'ru-ru-x-ruc-local', locale: 'ru-RU'),
      SystemVoice(name: 'ru-ru-x-ruc-network', locale: 'ru-RU'),
    ]);
    expect(voices!.map((v) => (v.lang, v.needsInternet)),
        [('ru', false), ('ru', true)]);
  });

  test('a platform that can\'t list voices answers null', () async {
    voiceList = null;
    expect(await FlutterTtsSpeaker().voices(), isNull);
  });
}
