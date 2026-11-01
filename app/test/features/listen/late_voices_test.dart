import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/listen/listen_chain.dart';
import 'package:trellis/features/listen/listen_jobs.dart';
import 'package:trellis/features/reader/speech/phone_voice.dart';
import 'package:trellis/services/device_services.dart' show SystemVoice;

import '../../support/fake_services.dart';

/// Seen on the emulator after a cold start: Android's speech engine took
/// longer than the five seconds the app waits to say which voices it has.
/// The late answer was thrown away, so a learning language spoken by the
/// phone's voice (Russian) was offered nowhere, and every row lost its
/// second button until the app went to the background and back.
void main() {
  test('a late answer from the phone still arrives, and is heard', () async {
    final answer = Completer<PhoneVoices?>();
    final cache = PhoneVoiceCache(_SlowSaver(answer.future),
        timeout: const Duration(milliseconds: 10));
    var heard = 0;
    cache.addListener(() => heard++);

    await cache.refresh();
    expect(cache.langs, isEmpty, reason: 'nothing yet: the wait ran out');

    answer.complete(PhoneVoices(
        engine: 'Speech Services by Google',
        voices: [SystemVoice(name: 'ru-x-local', locale: 'ru')]));
    await pumpEventQueue();

    expect(cache.langs, contains('ru'));
    expect(heard, 1);
  });

  test('when the phone’s voices change, what can be made is asked again',
      () async {
    final dir = Directory.systemTemp.createTempSync('trellis-late-voices');
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async {
      await db.close();
      dir.deleteSync(recursive: true);
    });
    final voices = ChangeNotifier();
    var offered = ['es'];
    final services = testServices(dir);
    final jobs = ListenJobs(
      db: db,
      chain: ListenChain(
        db: db,
        transcribe: (w, e) async {},
        translate: (w, s, t, p) async => null,
        voiceFor: (w, l) async => null,
        audioFileFor: services.audioFileFor,
        tempDir: Directory('${dir.path}/tmp'),
      ),
      languagesFor: ({required workLang, required feedLang}) => offered,
      downloadsFor: (w, e, l) async => const [],
      voices: voices,
    );
    await jobs.ready;
    var told = 0;
    jobs.addListener(() => told++);
    expect(jobs.languagesOfForTest(workLang: 'en', feedLang: null), ['es']);

    offered = ['es', 'ru'];
    voices.notifyListeners();

    expect(told, greaterThan(0));
    expect(jobs.languagesOfForTest(workLang: 'en', feedLang: null),
        ['es', 'ru']);
  });
}

class _SlowSaver extends FakePhoneSpeechSaver {
  _SlowSaver(this.answer) : super(const []);
  final Future<PhoneVoices?> answer;

  @override
  Future<PhoneVoices?> voices() => answer;
}
