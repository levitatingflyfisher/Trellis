/// What works today in each language (owner, 12 Nov: "pick ANY language
/// to learn ... show plainly what works today: reading, cards,
/// transcribing (whisper), translating, speaking").
///
/// Pure: the device's models and voices come in as plain sets and a
/// route function, so the rule is tested without a phone.
library;

/// One thing in one language, today, on this phone.
enum Ability {
  works('works'),
  download('needs a download'),
  notYet('is not there yet');

  const Ability(this.spoken);
  final String spoken;

  /// The better of two.
  Ability or(Ability other) => index <= other.index ? this : other;
}

/// Which ways a translator goes, for a language other than English.
enum TranslateWays {
  both('both ways'),
  fromEnglish('from English'),
  intoEnglish('into English');

  const TranslateWays(this.label);
  final String label;
}

class LanguageAbilities {
  const LanguageAbilities({
    required this.lang,
    required this.transcribe,
    required this.translate,
    required this.translateWays,
    required this.speak,
    required this.makesEpisodes,
  });

  final String lang;

  /// Text in any language can be read, and cards made from it.
  Ability get reading => Ability.works;
  Ability get cards => Ability.works;

  /// Whisper turns its speech into text.
  final Ability transcribe;

  /// A translator reaches it from English or reaches English from it,
  /// directly or by way of English. English itself needs none.
  final Ability translate;

  /// Null for English and where nothing translates it.
  final TranslateWays? translateWays;

  /// A voice here, or one to download, speaks it.
  final Ability speak;

  /// The one tap can make an episode in it today (all three engines, or
  /// their downloads, line up).
  final bool makesEpisodes;

  /// The row in words, for a screen reader.
  String spoken(String name) {
    final ways = translateWays == null ? '' : ', ${translateWays!.label}';
    return '$name. Reading ${reading.spoken}. '
        'Cards ${cards == Ability.works ? 'work' : cards.spoken}. '
        'Transcribing ${transcribe.spoken}. '
        'Translating ${translate.spoken}$ways. '
        'Speaking ${speak.spoken}.';
  }
}

/// The 99 languages of whisper's tiny, base and small models, as ISO
/// 639-1 codes (whisper writes Javanese "jw"; it is "jv" here), plus
/// Hawaiian. Cantonese came only with large-v3, which Trellis does not
/// carry.
const Set<String> whisperLanguages = {
  'en', 'zh', 'de', 'es', 'ru', 'ko', 'fr', 'ja', 'pt', 'tr', 'pl', 'ca', //
  'nl', 'ar', 'sv', 'it', 'id', 'hi', 'fi', 'vi', 'he', 'uk', 'el', 'ms', //
  'cs', 'ro', 'da', 'hu', 'ta', 'no', 'th', 'ur', 'hr', 'bg', 'lt', 'la', //
  'mi', 'ml', 'cy', 'sk', 'te', 'fa', 'lv', 'bn', 'sr', 'az', 'sl', 'kn', //
  'et', 'mk', 'br', 'eu', 'is', 'hy', 'ne', 'mn', 'bs', 'kk', 'sq', 'sw', //
  'gl', 'mr', 'pa', 'si', 'km', 'sn', 'yo', 'so', 'af', 'oc', 'ka', 'be', //
  'tg', 'sd', 'gu', 'am', 'yi', 'lo', 'uz', 'fo', 'ht', 'ps', 'tk', 'nn', //
  'mt', 'sa', 'lb', 'my', 'bo', 'tl', 'mg', 'as', 'tt', 'haw', 'ln', 'ha', //
  'ba', 'jv', 'su',
};

/// Each of [languages], in the order given. [route] says whether a
/// translator goes from one language to another here ([Ability.works]),
/// after a download, or not at all. [whisperHere] is whether a whisper
/// model is on the phone already.
List<LanguageAbilities> languageAbilities({
  required Iterable<String> languages,
  required Set<String> whisperLanguages,
  required bool whisperHere,
  required Ability Function(String source, String target) route,
  required Set<String> voiceHere,
  required Set<String> voiceToDownload,
  required Set<String> makesEpisodes,
}) =>
    [
      for (final l in languages)
        _of(l,
            whisperLanguages: whisperLanguages,
            whisperHere: whisperHere,
            route: route,
            voiceHere: voiceHere,
            voiceToDownload: voiceToDownload,
            makesEpisodes: makesEpisodes),
    ];

LanguageAbilities _of(
  String l, {
  required Set<String> whisperLanguages,
  required bool whisperHere,
  required Ability Function(String source, String target) route,
  required Set<String> voiceHere,
  required Set<String> voiceToDownload,
  required Set<String> makesEpisodes,
}) {
  final transcribe = !whisperLanguages.contains(l)
      ? Ability.notYet
      : whisperHere
          ? Ability.works
          : Ability.download;
  Ability translate;
  TranslateWays? ways;
  if (l == 'en') {
    translate = Ability.works;
  } else {
    final into = route('en', l), from = route(l, 'en');
    translate = into.or(from);
    final i = into != Ability.notYet, f = from != Ability.notYet;
    ways = i && f
        ? TranslateWays.both
        : i
            ? TranslateWays.fromEnglish
            : f
                ? TranslateWays.intoEnglish
                : null;
  }
  final speak = voiceHere.contains(l)
      ? Ability.works
      : voiceToDownload.contains(l)
          ? Ability.download
          : Ability.notYet;
  return LanguageAbilities(
    lang: l,
    transcribe: transcribe,
    translate: translate,
    translateWays: ways,
    speak: speak,
    makesEpisodes: makesEpisodes.contains(l),
  );
}
