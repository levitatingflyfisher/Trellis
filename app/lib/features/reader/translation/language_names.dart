/// The one ISO-639-1-code -> English display name table (Campaign 8
/// "Babel widens" Phase 1): the "Translate…" picker's option labels, the
/// generalized "Show ⟨language⟩"/"Speak in ⟨language⟩" menu items, and
/// the work-language selector all read through this so the app can never
/// name the same language two different ways on two different screens.
library;

const Map<String, String> _kLanguageNames = {
  'en': 'English',
  'es': 'Spanish',
  'de': 'German',
  'ru': 'Russian',
  'zh': 'Chinese',
  'ja': 'Japanese',
  'pt': 'Portuguese',
  'fr': 'French',
  'ko': 'Korean',
  'it': 'Italian',
  'nl': 'Dutch',
  'ar': 'Arabic',
  'hi': 'Hindi',
  'uk': 'Ukrainian',
  'pl': 'Polish',
};

/// The display name for ISO-639-1 [code] — falls back to the code itself,
/// uppercased, for anything not in the table above (never blank, never a
/// throw — a language the picker somehow offers without a name still
/// shows SOMETHING legible).
String languageDisplayName(String code) => _kLanguageNames[code] ?? code.toUpperCase();

/// Places a voice's locale names, in English: enough to tell apart the
/// voices a phone or browser lists for one language (1.5.9's Read aloud
/// voices sheet), where a bare "ru-RU" is a code, not a word.
const Map<String, String> _kRegionNames = {
  'AR': 'Argentina',
  'AT': 'Austria',
  'AU': 'Australia',
  'BE': 'Belgium',
  'BR': 'Brazil',
  'BY': 'Belarus',
  'CA': 'Canada',
  'CH': 'Switzerland',
  'CN': 'China',
  'CO': 'Colombia',
  'DE': 'Germany',
  'EG': 'Egypt',
  'ES': 'Spain',
  'FR': 'France',
  'GB': 'United Kingdom',
  'HK': 'Hong Kong',
  'IE': 'Ireland',
  'IN': 'India',
  'IT': 'Italy',
  'JP': 'Japan',
  'KR': 'South Korea',
  'KZ': 'Kazakhstan',
  'MX': 'Mexico',
  'NG': 'Nigeria',
  'NL': 'Netherlands',
  'NZ': 'New Zealand',
  'PL': 'Poland',
  'PT': 'Portugal',
  'RU': 'Russia',
  'SA': 'Saudi Arabia',
  'TW': 'Taiwan',
  'UA': 'Ukraine',
  'US': 'United States',
  'ZA': 'South Africa',
};

/// A locale ("ru-RU", or Android's "ru_RU") as words: "Russian (Russia)".
/// A place the table lacks keeps its code; no place, the language alone.
String localeDisplayName(String locale) {
  final parts = locale.split(RegExp('[-_]'));
  final lang = languageDisplayName(parts.first.toLowerCase());
  final region = parts.length > 1 && RegExp(r'^[A-Za-z]{2}$').hasMatch(parts[1])
      ? parts[1].toUpperCase()
      : null;
  if (region == null) return lang;
  return '$lang (${_kRegionNames[region] ?? region})';
}

/// The calm per-work source-language selector's own options (Campaign 8
/// "Babel widens" Phase 1's "no auto-detection" ceiling: a curated list,
/// never a free-text field or a guess) — every code [languageDisplayName]
/// names: English first, the rest in the order their English names sort.
const List<String> selectableWorkLanguages = [
  'en', 'ar', 'zh', 'nl', 'fr', 'de', 'hi', 'it', 'ja', 'ko', 'pl', 'pt',
  'ru', 'es', 'uk',
];

/// Whether [code]'s script runs right to left. Of the languages a pair
/// covers, only Arabic does.
bool isRightToLeft(String? code) => const {'ar', 'he', 'fa', 'ur'}.contains(code);
