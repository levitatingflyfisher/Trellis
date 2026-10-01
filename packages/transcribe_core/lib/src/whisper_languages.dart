/// Which language codes whisper accepts, and how a declared language (an
/// RSS `<language>`, a work's own) becomes one.
library;

/// whisper.cpp's language table (`g_lang` in `src/whisper.cpp`, v1.8.3).
/// Passing a code outside it makes `whisper_full` fail, so every language
/// handed to the engine goes through [whisperLanguageOf] first.
const Set<String> whisperLanguages = {
  'en', 'zh', 'de', 'es', 'ru', 'ko', 'fr', 'ja', 'pt', 'tr', 'pl', 'ca', //
  'nl', 'ar', 'sv', 'it', 'id', 'hi', 'fi', 'vi', 'he', 'uk', 'el', 'ms', //
  'cs', 'ro', 'da', 'hu', 'ta', 'no', 'th', 'ur', 'hr', 'bg', 'lt', 'la', //
  'mi', 'ml', 'cy', 'sk', 'te', 'fa', 'lv', 'bn', 'sr', 'az', 'sl', 'kn', //
  'et', 'mk', 'br', 'eu', 'is', 'hy', 'ne', 'mn', 'bs', 'kk', 'sq', 'sw', //
  'gl', 'mr', 'pa', 'si', 'km', 'sn', 'yo', 'so', 'af', 'oc', 'ka', 'be', //
  'tg', 'sd', 'gu', 'am', 'yi', 'lo', 'uz', 'fo', 'ht', 'ps', 'tk', 'nn', //
  'mt', 'sa', 'lb', 'my', 'bo', 'tl', 'mg', 'as', 'tt', 'haw', 'ln', 'ha', //
  'ba', 'jw', 'su', 'yue',
};

/// Whisper's English names for its languages (the same table), for a feed
/// that spells the language out instead of coding it.
const Map<String, String> _names = {
  'english': 'en',
  'chinese': 'zh',
  'german': 'de',
  'spanish': 'es',
  'russian': 'ru',
  'korean': 'ko',
  'french': 'fr',
  'japanese': 'ja',
  'portuguese': 'pt',
  'turkish': 'tr',
  'polish': 'pl',
  'catalan': 'ca',
  'dutch': 'nl',
  'arabic': 'ar',
  'swedish': 'sv',
  'italian': 'it',
  'indonesian': 'id',
  'hindi': 'hi',
  'finnish': 'fi',
  'vietnamese': 'vi',
  'hebrew': 'he',
  'ukrainian': 'uk',
  'greek': 'el',
  'malay': 'ms',
  'czech': 'cs',
  'romanian': 'ro',
  'danish': 'da',
  'hungarian': 'hu',
  'tamil': 'ta',
  'norwegian': 'no',
  'thai': 'th',
  'urdu': 'ur',
  'croatian': 'hr',
  'bulgarian': 'bg',
  'lithuanian': 'lt',
  'latin': 'la',
  'maori': 'mi',
  'malayalam': 'ml',
  'welsh': 'cy',
  'slovak': 'sk',
  'telugu': 'te',
  'persian': 'fa',
  'latvian': 'lv',
  'bengali': 'bn',
  'serbian': 'sr',
  'azerbaijani': 'az',
  'slovenian': 'sl',
  'kannada': 'kn',
  'estonian': 'et',
  'macedonian': 'mk',
  'breton': 'br',
  'basque': 'eu',
  'icelandic': 'is',
  'armenian': 'hy',
  'nepali': 'ne',
  'mongolian': 'mn',
  'bosnian': 'bs',
  'kazakh': 'kk',
  'albanian': 'sq',
  'swahili': 'sw',
  'galician': 'gl',
  'marathi': 'mr',
  'punjabi': 'pa',
  'sinhala': 'si',
  'khmer': 'km',
  'shona': 'sn',
  'yoruba': 'yo',
  'somali': 'so',
  'afrikaans': 'af',
  'occitan': 'oc',
  'georgian': 'ka',
  'belarusian': 'be',
  'tajik': 'tg',
  'sindhi': 'sd',
  'gujarati': 'gu',
  'amharic': 'am',
  'yiddish': 'yi',
  'lao': 'lo',
  'uzbek': 'uz',
  'faroese': 'fo',
  'haitian creole': 'ht',
  'pashto': 'ps',
  'turkmen': 'tk',
  'nynorsk': 'nn',
  'maltese': 'mt',
  'sanskrit': 'sa',
  'luxembourgish': 'lb',
  'myanmar': 'my',
  'tibetan': 'bo',
  'tagalog': 'tl',
  'malagasy': 'mg',
  'assamese': 'as',
  'tatar': 'tt',
  'hawaiian': 'haw',
  'lingala': 'ln',
  'hausa': 'ha',
  'bashkir': 'ba',
  'javanese': 'jw',
  'sundanese': 'su',
  'cantonese': 'yue',
};

/// Tags that must not fall to their primary subtag or whisper's own code:
/// Cantonese is a Chinese tag but its own whisper language, and several
/// codes feeds use are filed under another one (Bokmal and Nynorsk both
/// under `no`, Filipino as Tagalog, Moldovan as Romanian).
const Map<String, String> _aliases = {
  'zh-yue': 'yue',
  'zh-hk': 'yue',
  'zh-mo': 'yue',
  'nb': 'no',
  'nn': 'no',
  'jv': 'jw',
  'fil': 'tl',
  'mo': 'ro',
};

/// ISO 639 codes withdrawn in 1989 that RSS feeds still declare.
const Map<String, String> _legacy = {'iw': 'he', 'in': 'id', 'ji': 'yi'};

/// The whisper code for a declared language tag (`en-us`, `ru-RU`, `es`),
/// or null — meaning let whisper detect — when there is none or whisper
/// doesn't know it.
String? whisperLanguageOf(String? tag) {
  if (tag == null) return null;
  final whole = tag.trim().toLowerCase();
  final named = _names[whole];
  if (named != null) return _aliases[named] ?? named;
  final parts = whole.split(RegExp('[-_]'));
  final primary = parts.first;
  final region = parts.length > 1 ? '$primary-${parts[1]}' : primary;
  final code =
      _aliases[region] ?? _aliases[primary] ?? _legacy[primary] ?? primary;
  return whisperLanguages.contains(code) ? code : null;
}
