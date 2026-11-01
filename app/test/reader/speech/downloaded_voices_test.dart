import 'package:flutter_test/flutter_test.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:trellis/features/reader/speech/downloaded_voices.dart';
import 'package:trellis/features/reader/speech/speech_engine.dart';

import '../../support/fake_synthesis_engine.dart';

/// Trellis's own voices, one per language (owner, 13 Nov, board-0211):
/// every downloaded voice behind one engine, each sentence said by the
/// voice for its language.
void main() {
  late Map<String, FakeSynthesisSpeechEngine> opened;
  late List<String> opens;

  DownloadedVoices voices(Map<String, String> voiceByLang) {
    opened = {};
    opens = [];
    return DownloadedVoices(
      voiceByLang: voiceByLang,
      open: (id) async {
        opens.add(id);
        return opened[id] = FakeSynthesisSpeechEngine();
      },
    );
  }

  test('it speaks exactly the languages it has a voice for', () {
    final v = voices({'de': 'pocket-de', 'zh': 'kokoro-zh'});
    expect(v.speaks, {'de', 'zh'});
    expect(v.canPause, isTrue);
  });

  test('a sentence goes to the voice for its language, region tags '
      'included', () async {
    final v = voices({'de': 'pocket-de', 'zh': 'kokoro-zh'});
    fire(v.synthesize('Guten Tag.', lang: 'de-AT'));
    fire(v.synthesize('你好。', lang: 'zh'));
    await pumpEventQueue();
    expect(opened['pocket-de']!.calls.single.text, 'Guten Tag.');
    expect(opened['pocket-de']!.calls.single.lang, 'de');
    expect(opened['kokoro-zh']!.calls.single.text, '你好。');
  });

  test('a voice opens once, on its first sentence, and one voice that '
      'is registered for several languages opens once for all', () async {
    final v = voices({'es': 'multi', 'fr': 'multi', 'de': 'p'});
    fire(v.synthesize('Hola.', lang: 'es'));
    fire(v.synthesize('Salut.', lang: 'fr'));
    fire(v.synthesize('Hola otra vez.', lang: 'es'));
    await pumpEventQueue();
    expect(opens, ['multi']);
    expect(opened['multi']!.calls.map((c) => c.lang), ['es', 'fr', 'es']);
  });

  test('a language with no voice is refused in a sentence, never said '
      'by another language’s voice', () async {
    final v = voices({'de': 'pocket-de'});
    expect(() => v.synthesize('Привет.', lang: 'ru'),
        throwsA(isA<DownloadedVoiceLangException>()));
    expect(opens, isEmpty);
  });

  test('no language named: English when there is an English voice, else '
      'the one voice there is', () async {
    final both = voices({'en': 'en-voice', 'de': 'de-voice'});
    fire(both.synthesize('Hello.'));
    await pumpEventQueue();
    expect(opens, ['en-voice']);

    final one = voices({'de': 'de-voice'});
    fire(one.synthesize('Hallo.'));
    await pumpEventQueue();
    expect(opens, ['de-voice']);
  });

  test('dispose releases every voice it opened, and only those', () async {
    final v = voices({'de': 'pocket-de', 'zh': 'kokoro-zh'});
    fire(v.synthesize('Hallo.', lang: 'de'));
    await pumpEventQueue();
    await v.dispose();
    expect(opened['pocket-de']!.disposed, isTrue);
    expect(opened.containsKey('kokoro-zh'), isFalse);
  });

  test('a voice that fails to open is tried again on the next sentence',
      () async {
    var fail = true;
    FakeSynthesisSpeechEngine? engine;
    final v = DownloadedVoices(
      voiceByLang: const {'de': 'pocket-de'},
      open: (id) async {
        if (fail) throw StateError('no file');
        return engine = FakeSynthesisSpeechEngine();
      },
    );
    await expectLater(v.synthesize('Hallo.', lang: 'de'), throwsStateError);
    fail = false;
    fire(v.synthesize('Hallo.', lang: 'de'));
    await pumpEventQueue();
    expect(engine!.calls.single.text, 'Hallo.');
  });

  test('the pace reaches the voice', () async {
    final v = voices({'de': 'pocket-de'});
    fire(v.synthesize('Hallo.',
        lang: 'de', pace: const SpeechPace(rate: 0.8, careful: true)));
    await pumpEventQueue();
    expect(opened['pocket-de']!.paces.single,
        const SpeechPace(rate: 0.8, careful: true));
  });

  test('every voice in the catalog is named by its engine on an '
      'episode’s page, never by its id', () {
    final starter = ModelRegistry.starter();
    expect(downloadedVoiceName(starter.byId('pocket-es')!), 'Pocket TTS');
    expect(downloadedVoiceName(starter.byId('kokoro-zh-zf001')!), 'Kokoro');
    for (final s in starter.specs.where((s) => s.task == ModelTask.tts)) {
      expect(downloadedVoiceName(s), isIn(['Pocket TTS', 'Kokoro']),
          reason: s.id);
    }
  });
}

void fire(Future<void> f) => f.then((_) {}, onError: (_) {});
