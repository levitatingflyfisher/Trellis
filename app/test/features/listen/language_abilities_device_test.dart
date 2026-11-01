import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/listen/language_abilities.dart';
import 'package:trellis/features/listen/listen_device.dart';
import 'package:trellis/features/reader/speech/phone_voice.dart';

import '../../support/fake_services.dart';

/// The rows the learning-language picker shows, read from what is really
/// on the phone: downloaded models, and the phone's own voices.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('trellis-abilities'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<Map<String, LanguageAbilities>> abilities(
      {Set<String> downloaded = const {},
      List<String> voices = const []}) async {
    final phone = PhoneVoiceCache(FakePhoneSpeechSaver(voices));
    await phone.refresh();
    final services = testServices(dir,
        modelStore: FakeModelStore(downloadedIds: {...downloaded}),
        phoneVoices: phone);
    return {
      for (final a in await deviceLanguageAbilities(services)) a.lang: a,
    };
  }

  test('every language Trellis can name has a row', () async {
    final all = await abilities();
    expect(all.length, greaterThan(180));
    expect(all.keys, containsAll(['cy', 'sw', 'ru', 'ja', 'en']));
  });

  test('Russian with its pair, whisper and a phone voice: all five work, '
      'and episodes can be made', () async {
    final ru = (await abilities(
        downloaded: {'opus-mt-en-ru', 'opus-mt-ru-en', 'whisper-tiny-ggml'},
        voices: ['ru']))['ru']!;
    expect(ru.transcribe, Ability.works);
    expect(ru.translate, Ability.works);
    expect(ru.translateWays, TranslateWays.both);
    expect(ru.speak, Ability.works);
    expect(ru.makesEpisodes, isTrue);
  });

  test('nothing downloaded: whisper and the pairs are downloads, the '
      'downloadable voice too', () async {
    final all = await abilities();
    expect(all['ru']!.transcribe, Ability.download);
    expect(all['ru']!.translate, Ability.download);
    expect(all['es']!.speak, Ability.download);
    expect(all['ru']!.speak, Ability.notYet, reason: 'no phone voice');
  });

  test('a small language: whisper hears Welsh; no translator or voice',
      () async {
    final cy = (await abilities(downloaded: {'whisper-tiny-ggml'}))['cy']!;
    expect(cy.transcribe, Ability.works);
    expect(cy.translate, Ability.notYet);
    expect(cy.speak, Ability.notYet);
    expect(cy.makesEpisodes, isFalse);
  });

  test('Polish translates into English only', () async {
    final pl = (await abilities())['pl']!;
    expect(pl.translateWays, TranslateWays.intoEnglish);
  });
}
