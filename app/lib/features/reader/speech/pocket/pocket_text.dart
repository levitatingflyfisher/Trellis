/// What the Pocket TTS model is given for one sentence: Kyutai's
/// `prepare_text_prompt` (pocket_tts/models/text_chunking.py) and each
/// language's settings (`pocket_tts/config/<language>.yaml`), ported.
///
/// Pocket TTS by Kyutai, MIT code; the settings are the ones Kyutai
/// ships with each language's weights. The model reads plain text
/// through its own tokenizer: there is no phonemizer here, and nothing
/// for espeak to hide in.
library;

/// The seven languages Kyutai trained a 6-layer Pocket TTS model for,
/// each with the rewrites its config applies before tokenizing.
enum PocketLanguage {
  english('en', removeSemicolons: false, replace: {
    '’': "'",
    '‘': "'",
  }),
  german('de', removeSemicolons: true, replace: {
    ..._quotesAndBrackets,
    '–': ',',
    '—': ',',
  }),
  spanish('es', removeSemicolons: false, replace: {
    ..._quotesAndBrackets,
    '¡': '',
    '¿': '',
    '–': ',',
  }),
  french('fr', removeSemicolons: true, replace: {
    ..._quotesAndBrackets,
    ':': ',',
    '–': ',',
  }),
  italian('it', removeSemicolons: false, replace: {
    ..._quotesAndBrackets,
    '–': ',',
  }),
  portuguese('pt', removeSemicolons: false, replace: {
    ..._quotesAndBrackets,
    '–': ',',
  }),
  dutch('nl', removeSemicolons: false, replace: {
    ..._quotesAndBrackets,
    '–': ',',
  });

  const PocketLanguage(this.tag,
      {required this.removeSemicolons, required this.replace});

  /// The bare language tag Trellis uses.
  final String tag;

  /// `remove_semicolons`: a semicolon is read as a comma.
  final bool removeSemicolons;

  /// `replace_characters`: characters the training text never had
  /// ("" deletes); their embeddings are untrained, and the model says
  /// filler syllables where they occur.
  final Map<String, String> replace;

  static PocketLanguage? byTag(String tag) {
    for (final l in values) {
      if (l.tag == tag) return l;
    }
    return null;
  }
}

// not-rendered: characters the model's own preparation deletes, never
// drawn by the app (C7-fonts, oh_fleet_conformance).
const _quotesAndBrackets = {
  '"': '',
  '“': '',
  '”': '',
  '„': '',
  '«': '',
  '»': '',
  '’': "'",
  '‘': "'",
  '(': '',
  ')': '',
  '[': '',
  ']': '',
};

/// Python's `str.upper()` follows Unicode's special casing, where one
/// letter's capital is several; Dart's `toUpperCase` keeps these as they
/// are. The ones a sentence can start with (Unicode SpecialCasing.txt).
const _specialUpper = {
  'ß': 'SS',
  'ŉ': 'ʼN', // not-rendered
  'ﬀ': 'FF', // not-rendered
  'ﬁ': 'FI', // not-rendered
  'ﬂ': 'FL', // not-rendered
  'ﬃ': 'FFI', // not-rendered
  'ﬄ': 'FFL', // not-rendered
  'ﬅ': 'ST', // not-rendered
  'ﬆ': 'ST', // not-rendered
};

/// One sentence as the model reads it, and how many frames to let run
/// after the model says it is done ([framesAfterEos]: 3 for a short
/// sentence of four words or fewer, else 1; Kyutai's guess).
class PocketPrompt {
  final String text;
  final int framesAfterEos;
  const PocketPrompt(this.text, this.framesAfterEos);
}

final _space = RegExp(r'\s+');
final _markThenWeak = RegExp('([.!?…])\\s*[,;:]');
const _terminal = '.!?…';
const _weak = ',;:-–—';
// Escaped: these are characters to match, not copy on screen.
const _closers = '\u0022\u0027\u201D\u2019)]\u00BB';

/// [text] prepared for [lang]. Throws [ArgumentError] when nothing is
/// left to say.
PocketPrompt preparePocketText(String text, PocketLanguage lang) {
  var t = text.trim();
  if (lang.replace.isNotEmpty) {
    final b = StringBuffer();
    for (final r in t.runes) {
      final c = String.fromCharCode(r);
      b.write(lang.replace[c] ?? c);
    }
    t = _words(b.toString()).join(' ');
    t = t.replaceAllMapped(_markThenWeak, (m) => m[1]!);
  }
  if (t.isEmpty) throw ArgumentError('Text prompt cannot be empty');
  t = t.replaceAll('\n', ' ').replaceAll('\r', ' ').replaceAll('  ', ' ');
  if (lang.removeSemicolons) t = t.replaceAll(';', ',');
  final framesAfterEos = _words(t).length <= 4 ? 3 : 1;

  // `if not text[0].isupper(): text = text[0].upper() + text[1:]`. A
  // character with no case upper-cases to itself.
  final first = String.fromCharCode(t.runes.first);
  final isUpper =
      first == first.toUpperCase() && first != first.toLowerCase();
  if (!isUpper) {
    t = (_specialUpper[first] ?? first.toUpperCase()) +
        t.substring(first.length);
  }
  return PocketPrompt(_ensureTerminal(t), framesAfterEos);
}

List<String> _words(String s) =>
    s.trim().split(_space).where((w) => w.isNotEmpty).toList();

/// Kyutai's `_ensure_terminal_punctuation`.
String _ensureTerminal(String text) {
  var end = text.length;
  while (end > 0 && ('$_closers ').contains(text[end - 1])) {
    end--;
  }
  final core = text.substring(0, end);
  final closers = text.substring(end).trim();
  if (core.isEmpty || _terminal.contains(core[core.length - 1])) return text;
  if (_weak.contains(core[core.length - 1])) {
    var c = core.length;
    while (c > 0 && ('$_weak ').contains(core[c - 1])) {
      c--;
    }
    return '${core.substring(0, c)}.$closers';
  }
  return '$text.';
}
