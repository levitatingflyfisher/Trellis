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
};

/// The display name for ISO-639-1 [code] — falls back to the code itself,
/// uppercased, for anything not in the table above (never blank, never a
/// throw — a language the picker somehow offers without a name still
/// shows SOMETHING legible).
String languageDisplayName(String code) => _kLanguageNames[code] ?? code.toUpperCase();

/// The calm per-work source-language selector's own options (Campaign 8
/// "Babel widens" Phase 1's "no auto-detection" ceiling: a curated list,
/// never a free-text field or a guess) — every code [languageDisplayName]
/// names, English first since it is the declared default for a work with
/// nothing set.
const List<String> selectableWorkLanguages = [
  'en', 'es', 'de', 'ru', 'zh', 'ja', 'pt', 'fr', 'ko',
];
