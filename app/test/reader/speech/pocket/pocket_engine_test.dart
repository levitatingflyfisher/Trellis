import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/reader/speech/pocket/pocket_engine.dart';
import 'package:trellis/features/reader/speech/pocket/pocket_text.dart';
import 'package:trellis/features/reader/speech/speech_engine.dart';

/// PocketSpeechEngine with the model faked at [PocketModel].
class _FakeModel implements PocketModel {
  final calls = <({String text, int steps})>[];
  bool disposed = false;
  Object? fail;
  @override
  Future<Float32List> say(String text, {required int steps}) async {
    if (fail case final f?) throw f;
    calls.add((text: text, steps: steps));
    return Float32List(24000); // one second
  }

  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  late _FakeModel model;
  var opens = 0;
  PocketSpeechEngine engine({PocketLanguage lang = PocketLanguage.german}) {
    model = _FakeModel();
    opens = 0;
    return PocketSpeechEngine(
        language: lang,
        open: () async {
          opens++;
          return model;
        });
  }

  test('it speaks its one language, and can pause', () {
    final e = engine();
    expect(e.speaks, {'de'});
    expect(e.canPause, isTrue);
    expect(() => e.synthesize('Bonjour', lang: 'fr'),
        throwsA(isA<PocketUnsupportedLangException>()));
  });

  test('natural pace: one flow step, the audio as made, at 24 kHz',
      () async {
    final e = engine();
    final r = await e.synthesize('Guten Tag.', lang: 'de-DE');
    expect(model.calls.single, (text: 'Guten Tag.', steps: 1));
    expect(r.sampleRate, 24000);
    expect(r.samples.length, 24000);
  });

  test('careful: four flow steps; a slower rate adds a pause after the '
      'sentence, since the model has no speed of its own', () async {
    final e = engine();
    final r = await e.synthesize('Guten Tag.',
        lang: 'de', pace: const SpeechPace(rate: 0.75, careful: true));
    expect(model.calls.single.steps, 4);
    // One second at 0.75: a third of a second more, in silence.
    expect(r.samples.length, 24000 + 8000);
    expect(r.samples.skip(24000).every((s) => s == 0), isTrue);
  });

  test('the pause is never longer than two seconds', () async {
    final e = engine();
    final r = await e.synthesize('Guten Tag.',
        lang: 'de', pace: const SpeechPace(rate: 0.1));
    expect(r.samples.length, 24000 + 48000);
  });

  test('opens once, on first use, and again after a failed open; '
      'dispose releases it', () async {
    var fail = true;
    final good = _FakeModel();
    final e = PocketSpeechEngine(
        language: PocketLanguage.german,
        open: () async {
          if (fail) throw StateError('boom');
          return good;
        });
    await expectLater(e.synthesize('Hallo.', lang: 'de'),
        throwsA(isA<PocketNativeInitException>()));
    fail = false;
    await e.synthesize('Hallo.', lang: 'de');
    await e.synthesize('Welt.', lang: 'de');
    expect(good.calls, hasLength(2));
    await e.dispose();
    expect(good.disposed, isTrue);
  });

  test('one sentence at a time, in order', () async {
    final e = engine();
    final a = e.synthesize('Eins.', lang: 'de');
    final b = e.synthesize('Zwei.', lang: 'de');
    await Future.wait([a, b]);
    expect(model.calls.map((c) => c.text), ['Eins.', 'Zwei.']);
    expect(opens, 1);
  });
}
