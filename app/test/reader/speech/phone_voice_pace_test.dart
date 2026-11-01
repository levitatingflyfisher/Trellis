import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/reader/speech/phone_voice.dart';
import 'package:trellis/features/reader/speech/speech_engine.dart';

import '../../support/fake_services.dart';

/// How clearly a made episode is spoken, on the phone's own voice: the
/// pace asked for is Android's speech rate for that sentence (1.0 is the
/// voice's own). Android has no setting for more careful sounds, so
/// [SpeechPace.careful] does nothing here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('trellis-phone-pace'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('the pace asked for is the rate the phone is asked to say it at; '
      'none asked for is the voice’s own', () async {
    final saver = FakePhoneSpeechSaver(['ru']);
    await sayWithPhone(saver, 'Один.', lang: 'ru', dir: dir);
    await sayWithPhone(saver, 'Два.',
        lang: 'ru',
        dir: dir,
        pace: const SpeechPace(rate: 0.75, careful: true));
    expect(saver.rates, [1.0, 0.75]);
  });

  test('the rate travels over the channel to Android, beside the sentence',
      () async {
    const channel = MethodChannel('com.openhearth.trellis/phone_voice');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    await MethodChannelPhoneSpeechSaver()
        .sayToFile('Hola.', lang: 'es', path: '/x.wav', rate: 0.6);
    await MethodChannelPhoneSpeechSaver()
        .sayToFile('Adiós.', lang: 'es', path: '/y.wav');

    expect(calls.map((c) => c.method), ['sayToFile', 'sayToFile']);
    expect((calls[0].arguments as Map)['rate'], 0.6);
    expect((calls[1].arguments as Map)['rate'], 1.0);
  });
}
