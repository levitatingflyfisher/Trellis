import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/listen/language_abilities.dart';
import 'package:trellis/features/reader/translation/language_names.dart';

/// Owner, 12 Nov: "pick ANY language to learn", and for each one "show
/// plainly what works today: reading, cards, transcribing, translating,
/// speaking".
void main() {
  Ability routeOf(String s, String t) => switch ((s, t)) {
        ('en', 'ru') || ('ru', 'en') => Ability.works,
        ('en', 'sv') => Ability.download,
        _ => Ability.notYet,
      };

  List<LanguageAbilities> run({bool whisperHere = true}) => languageAbilities(
        languages: ['ru', 'sv', 'cy', 'en'],
        whisperLanguages: whisperLanguages,
        whisperHere: whisperHere,
        route: routeOf,
        voiceHere: {'ru'},
        voiceToDownload: {'es'},
        makesEpisodes: {'ru'},
      );

  LanguageAbilities of(List<LanguageAbilities> all, String l) =>
      all.singleWhere((a) => a.lang == l);

  test('every language reads and makes cards, whatever else it lacks', () {
    for (final a in run()) {
      expect(a.reading, Ability.works, reason: a.lang);
      expect(a.cards, Ability.works, reason: a.lang);
    }
  });

  test('a big language with everything here: all five work, both ways', () {
    final ru = of(run(), 'ru');
    expect(ru.transcribe, Ability.works);
    expect(ru.translate, Ability.works);
    expect(ru.translateWays, TranslateWays.both);
    expect(ru.speak, Ability.works);
    expect(ru.makesEpisodes, isTrue);
  });

  test('a translator not yet downloaded is a download, one way named', () {
    final sv = of(run(), 'sv');
    expect(sv.translate, Ability.download);
    expect(sv.translateWays, TranslateWays.fromEnglish);
    expect(sv.speak, Ability.notYet);
    expect(sv.makesEpisodes, isFalse);
  });

  test('a small language: whisper hears it, nothing translates or speaks it',
      () {
    final cy = of(run(), 'cy');
    expect(cy.transcribe, Ability.works);
    expect(cy.translate, Ability.notYet);
    expect(cy.translateWays, isNull);
    expect(cy.speak, Ability.notYet);
  });

  test('with no whisper model on the phone yet, hearing is a download', () {
    expect(of(run(whisperHere: false), 'ru').transcribe, Ability.download);
  });

  test('English needs no translator to itself', () {
    final en = of(run(), 'en');
    expect(en.translate, Ability.works);
    expect(en.translateWays, isNull);
  });

  test('a language whisper does not know is not transcribed', () {
    final all = languageAbilities(
      languages: ['ii'],
      whisperLanguages: whisperLanguages,
      whisperHere: true,
      route: routeOf,
      voiceHere: const {},
      voiceToDownload: const {},
      makesEpisodes: const {},
    );
    expect(all.single.transcribe, Ability.notYet);
  });

  test('whisper\'s languages are named codes, Javanese under ISO jv', () {
    expect(whisperLanguages, hasLength(99));
    expect(whisperLanguages, contains('jv'));
    expect(whisperLanguages, isNot(contains('jw')));
    for (final l in whisperLanguages) {
      expect(languageDisplayName(l), isNot(l.toUpperCase()), reason: l);
    }
  });

  test('the picker can list every language: over 180, each named', () {
    expect(allLanguageCodes.length, greaterThan(180));
    expect(allLanguageCodes.toSet(), hasLength(allLanguageCodes.length));
    expect(allLanguageCodes, containsAll(['cy', 'sw', 'yue', 'ru', 'en']));
  });

  test('a plain spoken summary of a row, for a screen reader', () {
    expect(
        of(run(), 'sv').spoken('Swedish'),
        'Swedish. Reading works. Cards work. Transcribing works. '
        'Translating needs a download, from English. Speaking is not '
        'there yet.');
  });
}
