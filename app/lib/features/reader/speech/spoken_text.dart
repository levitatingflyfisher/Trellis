/// What read aloud leaves unsaid (1.6.0, owner: read aloud "speaks every
/// inline citation in the personal finance book, which makes it painful
/// to listen to").
///
/// A voice reading "open bracket Smith comma twenty nineteen" tells the
/// listener nothing they can use. So, unless the listener asks for them,
/// the voice skips: author and year in round brackets, numbers or keys in
/// square brackets, footnote marks, and bare links. The page keeps every
/// character; this only shapes the words handed to the voice.
///
/// It errs toward speaking: a bracket is skipped only when all of it
/// reads as a citation, so an aside that merely mentions a year, or an
/// editor's "[sic]", is still said.
library;

/// The device setting that turns citations back on in read aloud: `on`
/// speaks them; anything else, the default, skips them.
const speakCitationsKey = 'read_aloud_citations';

const _year = r'(?:(?:1[5-9]|20)\d{2}[a-z]?|n\.d\.|in press|forthcoming)';
const _nameWord = r'\p{Lu}[\p{L}\p{M}’\x27.\-]*';
const _joiner =
    r'(?:and|et al\.?|of|the|for|de|van|von|der|den|la|le|di|da|del|du)';
const _names = '$_nameWord(?:(?:\\s*,\\s*|\\s*&\\s*|\\s+)(?:$_nameWord|$_joiner))*';
const _locator =
    r'(?:pp?\.|ch\.|chap\.|chapter|sec\.|§|para\.|fig\.|figure|table|vol\.|n\.)'
    r'\s*[\p{L}\d–\-., ]+';
/// "…, as cited by Choi": a work known through another.
const _through = '(?:\\s*,?\\s*(?:as cited (?:by|in)|cited (?:by|in)|'
    'quoted (?:by|in)|via)\\s+$_names(?:,?\\s+$_year)?)';
const _leadIn = r'(?:(?:see also|see|e\.g\.,?|cf\.|compare|also)\s+)?';

/// One work inside round brackets: "Smith & Jones, 2019, pp. 4–9",
/// "see Lee et al., 2020a", or a year alone, "2011" / "1993, p. 12".
final _citedWork = RegExp(
    '^$_leadIn(?:($_names),?\\s+)?$_year(?:\\s*,\\s*$_year)*'
    '(?:\\s*,\\s*$_locator)?$_through?\$',
    unicode: true);

final _month = RegExp(
    r'^(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|'
    r'july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|'
    r'dec(?:ember)?|spring|summer|autumn|fall|winter)\.?$',
    caseSensitive: false);

/// A remark on the source after a semicolon: "original not opened".
final _aboutOriginal = RegExp(r'^(?:the )?original\b', caseSensitive: false);

bool _isAuthorYear(String inner) {
  final parts = inner.split(';');
  for (final (i, part) in parts.indexed) {
    if (i > 0 && _aboutOriginal.hasMatch(part.trim())) continue;
    final m = _citedWork.firstMatch(part.trim());
    if (m == null) return false;
    // "(March 2019)" is a date, not a work.
    final names = m.group(1);
    if (names != null && _month.hasMatch(names)) return false;
  }
  return true;
}

const _numberRun = r'\d{1,4}(?:\s*[–\-]\s*\d{1,4})?';
final _numbers = RegExp(
    '^$_numberRun(?:\\s*[,;]\\s*$_numberRun)*(?:\\s*,\\s*$_locator)?\$',
    unicode: true);

/// A citation key: no spaces, and either marked with @ or carrying a
/// digit ("Bog07", "SJ+20", "@bogle2007").
final _key = RegExp(r'^(?:@[\p{L}\d+:_\-]+|(?=[^\s]*\d)\p{L}[\p{L}\d+:_\-]*)$',
    unicode: true);
final _note = RegExp(r'^(?:citation needed|(?:note|n|nb)\s*\d+|[a-z])$',
    caseSensitive: false);

/// A source note: it carries a link, or the day the source was read, or
/// points back at the last source ("same, p. 4", "ibid.").
final _sourceNote = RegExp(
    r'https?://|www\.|\b(?:read|accessed|retrieved|viewed)\s+(?:on\s+)?'
    r'\d{4}-\d{2}-\d{2}|^(?:same|ibid\.?|op\. ?cit\.?)(?:[,.\s]|$)',
    caseSensitive: false);

bool _isSquareCitation(String inner) {
  final t = inner.trim();
  if (_numbers.hasMatch(t) || _note.hasMatch(t)) return true;
  if (_sourceNote.hasMatch(t) || _isAuthorYear(t)) return true;
  final keys = t.split(RegExp(r'\s*[,;]\s*'));
  return keys.every(_key.hasMatch);
}

final _round = RegExp(r'\s*\(([^()]{1,200})\)');
// Long enough for a source note with a full title and a long link.
final _square = RegExp(r'\s*\[([^\[\]]{1,1500})\]');

/// Raised digits, and the printer's dagger and double dagger.
final _raised = RegExp('[¹²³⁰-⁹†‡]+');

// In the patterns below the typewriter quote marks are written as escapes
// (\x22, \x27): the copy rule reads every string in lib/.

/// §, ¶ or * set tight against the end of a word, as a note mark: not
/// "§ 4 of the Act", which has a space before and a number after.
final _tightMark = RegExp(r'(?<=[\p{L}\d.,;:!?”\x22’)])[§¶*]+(?=[\s.,;:!?)]|$)',
    unicode: true);

/// A footnote number set tight after the punctuation that ends a word:
/// "first.12 Then". Never a decimal, whose point follows a digit.
final _tightNumber = RegExp(r'(?<=\p{L}[.,;:!?”\x22’)]{1,2})\d{1,3}(?=\s|$)',
    unicode: true);

final _link = RegExp(r'\s*(?:https?://|www\.)[^\s<>]+|\s*\bdoi:\s*10\.\d{4,9}/\S+',
    caseSensitive: false);
final _linkTail = RegExp(r'[.,;:!?)\]”\x22’\x27]+$');

final _bullet = RegExp(r'^\s*[•◦▪‣]\s+');
final _emptyBrackets = RegExp(r'\s*(?:\(\s*\)|\[\s*\])');
final _spaces = RegExp(r'\s{2,}');
final _spaceBeforeStop = RegExp(r'\s+(?=[.,;:!?)])');
final _sayable = RegExp(r'[\p{L}\d]', unicode: true);

/// [sentence] as read aloud says it: without its citations, footnote
/// marks and bare links. Returns [sentence] itself when it has none, and
/// the empty string when nothing sayable is left.
String spokenText(String sentence) {
  var out = sentence.replaceAllMapped(
      _round, (m) => _isAuthorYear(m.group(1)!) ? '' : m.group(0)!);
  out = out.replaceAllMapped(
      _square, (m) => _isSquareCitation(m.group(1)!) ? '' : m.group(0)!);
  out = out.replaceAllMapped(
      _link, (m) => _linkTail.firstMatch(m.group(0)!)?.group(0) ?? '');
  out = out
      .replaceAll(_raised, '')
      .replaceAll(_tightMark, '')
      .replaceAll(_tightNumber, '');
  // A list item's mark (Markdown intake writes "• ") is not a word.
  out = out.replaceFirst(_bullet, '');
  if (out == sentence) return sentence;
  out = out
      // What held only a link is now empty: "(https://…)" leaves "()".
      .replaceAll(_emptyBrackets, '')
      .replaceAll(_spaces, ' ')
      .replaceAll(_spaceBeforeStop, '')
      .trim();
  return _sayable.hasMatch(out) ? out : '';
}
