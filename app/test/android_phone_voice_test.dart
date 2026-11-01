import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The phone's own voice, saved to a file (board-0126): the Android half,
/// which no widget test can run. These hold the two halves to one
/// contract by name: the channel, its three calls, and what Android
/// needs to let the app see its text-to-speech engines at all.
void main() {
  String read(String path) => File(path).readAsStringSync();
  const kotlin =
      'android/app/src/main/kotlin/com/openhearth/trellis/PhoneVoice.kt';

  test('the app may see the phone’s text-to-speech engines', () {
    // From Android 11, an app sees only the packages it declares; a
    // TextToSpeech bound without this finds no engine at all.
    expect(
        RegExp(r'<queries>.*<action android:name="android\.intent\.action\.'
                r'TTS_SERVICE"\s*/>.*</queries>',
                dotAll: true)
            .hasMatch(read('android/app/src/main/AndroidManifest.xml')),
        isTrue);
  });

  test('the activity opens the channel', () {
    expect(
        read('android/app/src/main/kotlin/com/openhearth/trellis/'
            'MainActivity.kt'),
        contains('PhoneVoice.attach('));
  });

  test('both halves name the same channel and calls', () {
    final k = read(kotlin);
    final d = read('lib/features/reader/speech/phone_voice.dart');
    const channel = 'com.openhearth.trellis/phone_voice';
    expect(k, contains('"$channel"'));
    expect(d, contains("'$channel'"));
    for (final call in ['voices', 'sayToFile', 'openSettings']) {
      expect(k, contains('"$call" ->'), reason: call);
      expect(d, contains("invokeMethod<"), reason: call);
      expect(d, contains("'$call'"), reason: call);
    }
    for (final arg in ['text', 'lang', 'voice', 'path']) {
      expect(k, contains('argument<String>("$arg")'), reason: arg);
    }
  });

  test('every sentence is answered, failed or not, so a job never hangs',
      () {
    final k = read(kotlin);
    // Refused at the queue, an error from the engine, and a stop: each
    // ends the waiting call.
    expect(k, contains('!= TextToSpeech.SUCCESS'));
    expect(k, contains('override fun onError(utteranceId: String?, errorCode: Int)'));
    expect(k, contains('override fun onStop('));
    expect(k, contains('override fun onDone('));
  });

  test('the settings page is opened only where the phone has one', () {
    final k = read(kotlin);
    expect(k, contains('"com.android.settings.TTS_SETTINGS"'));
    expect(k, contains('ActivityNotFoundException'));
  });
}
