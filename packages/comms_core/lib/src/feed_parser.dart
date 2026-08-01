/// parseRssFeed port (donor index.html ~5734) on package:xml.
///
/// Element matching is by LOCAL name in any namespace, which mirrors what
/// the donor's `querySelector`/`getElementsByTagNameNS("*", …)` did in an
/// XML document. package:xml does not require namespace prefixes to be
/// declared, which makes this port slightly more tolerant than DOMParser
/// (a feed with an undeclared `itunes:` prefix parses here, errored there).
library;

import 'package:xml/xml.dart';

import 'exceptions.dart';
import 'feed_models.dart';
import 'limits.dart';

/// Decodes HTML character references (named, decimal, hex). The donor used a
/// `<textarea>` for this, which knows the full HTML5 named-entity table and
/// a legacy no-semicolon subset; this port decodes numeric references fully
/// and a ~100-name common subset, and requires the trailing semicolon.
String decodeHtmlEntities(String s) {
  if (s.isEmpty) return s;
  return s.replaceAllMapped(_entityRe, (m) {
    final body = m.group(1)!;
    if (body.startsWith('#')) {
      final isHex = body.length > 1 && (body[1] == 'x' || body[1] == 'X');
      final code =
          int.tryParse(body.substring(isHex ? 2 : 1), radix: isHex ? 16 : 10);
      if (code == null || code < 0 || code > 0x10FFFF) return m.group(0)!;
      if (code == 0 || (code >= 0xD800 && code <= 0xDFFF)) return '�';
      return String.fromCharCode(code);
    }
    return _namedEntities[body] ?? m.group(0)!;
  });
}

final _entityRe = RegExp(r'&(#[xX]?[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);');

final _isAudioUrlRe = RegExp(r'\.(mp3|m4a|ogg|wav|aac|opus|flac)(\?|#|$)',
    caseSensitive: false);

bool _isAudioUrl(String u) => _isAudioUrlRe.hasMatch(u);

final _tagRe = RegExp(r'<[^>]*>');

/// Donor cleanDesc: decode entities BEFORE stripping tags so entity-encoded
/// markup (&lt;script&gt;…) is removed by the strip rather than resurrected
/// as text (M21). Then trim and cap at 300 chars.
String _cleanDesc(String s) {
  final t = decodeHtmlEntities(s).replaceAll(_tagRe, '').trim();
  return t.length > 300 ? t.substring(0, 300) : t;
}

/// Donor parseTs: `HH:MM:SS(.ms)`, `MM:SS(.ms)` or bare seconds. Keeps the
/// donor's JS-number quirks: empty parts count as 0, unparseable multi-part
/// timestamps propagate NaN, a bare unparseable value collapses to 0.
double _parseTs(String? raw) {
  final s = (raw ?? '').trim();
  if (s.isEmpty) return 0;
  final parts = s.split(':').map(_jsNumber).toList();
  if (parts.length == 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
  if (parts.length == 2) return parts[0] * 60 + parts[1];
  final n = _jsNumber(s);
  return n.isNaN ? 0 : n; // Number(s)||0
}

double _jsNumber(String s) {
  final t = s.trim();
  if (t.isEmpty) return 0; // JS Number("") === 0
  return double.tryParse(t) ?? double.nan;
}

XmlElement? _firstLocal(Iterable<XmlElement> els, String local) {
  for (final e in els) {
    if (e.name.local == local) return e;
  }
  return null;
}

Iterable<XmlElement> _allLocal(Iterable<XmlElement> els, String local) =>
    els.where((e) => e.name.local == local);

/// Donor nsText: text of the first DIRECT child with this local name
/// (itunes:summary, content:encoded — querySelector can't cross namespaces).
String _nsText(XmlElement el, String local) {
  final n = _firstLocal(el.childElements, local);
  return n?.innerText ?? '';
}

({List<FeedChapter>? chapters, String? chaptersUrl}) _findChapters(
    XmlElement el) {
  // Direct-child <chapters> wrappers: psc:chapters (inline) or
  // podcast:chapters (url).
  for (final wrap in _allLocal(el.childElements, 'chapters')) {
    final inline = <FeedChapter>[
      for (final c in _allLocal(wrap.descendantElements, 'chapter'))
        FeedChapter(
          start: _parseTs(c.getAttribute('start')),
          title: c.getAttribute('title') ?? '',
          href: c.getAttribute('href') ?? '',
          image: c.getAttribute('image') ?? '',
        ),
    ];
    if (inline.isNotEmpty) return (chapters: inline, chaptersUrl: null);
    final u = wrap.getAttribute('url');
    if (u != null && u.isNotEmpty) return (chapters: null, chaptersUrl: u);
  }
  return (chapters: null, chaptersUrl: null);
}

/// The first direct-child `channel` or `feed` element in document order —
/// RSS 2.0 nests items under `<channel>`; Atom's own root IS `<feed>`.
XmlElement? _channelOrFeedRoot(XmlDocument d) {
  for (final e in d.descendantElements) {
    if (e.name.local == 'channel' || e.name.local == 'feed') return e;
  }
  return null;
}

/// RFC 5005 archive discovery: a channel/feed-level `<atom:link rel="next">`
/// (or, absent that, `rel="prev-archive"`) among its DIRECT children only —
/// an item/entry carrying the same rel must not leak into the feed level.
/// A relative href is resolved against [feedUrl]; an unresolvable or empty
/// href is treated as absent rather than thrown.
({String? url, String? rel}) _findNextPage(XmlDocument d, String feedUrl) {
  final container = _channelOrFeedRoot(d);
  if (container == null) return (url: null, rel: null);
  final links = _allLocal(container.childElements, 'link').toList();
  for (final rel in const ['next', 'prev-archive']) {
    for (final l in links) {
      if (l.getAttribute('rel') != rel) continue;
      final href = l.getAttribute('href');
      if (href == null || href.isEmpty) continue;
      try {
        return (url: Uri.parse(feedUrl).resolve(href).toString(), rel: rel);
      } catch (_) {
        return (url: href, rel: rel);
      }
    }
  }
  return (url: null, rel: null);
}

Enclosure? _findAudio(XmlElement el) {
  // Standard RSS 2.0 enclosure
  for (final enc in _allLocal(el.descendantElements, 'enclosure')) {
    final u = enc.getAttribute('url') ?? '';
    final t = enc.getAttribute('type') ?? '';
    if (u.isNotEmpty && (t.startsWith('audio/') || _isAudioUrl(u))) {
      return Enclosure(url: u, type: t);
    }
  }
  // Media RSS: <media:content> / <media:group><media:content>
  for (final mc in _allLocal(el.descendantElements, 'content')) {
    final u = mc.getAttribute('url') ?? '';
    final t = mc.getAttribute('type') ?? '';
    final medium = mc.getAttribute('medium') ?? '';
    if (u.isNotEmpty &&
        (t.startsWith('audio/') || medium == 'audio' || _isAudioUrl(u))) {
      return Enclosure(url: u, type: t);
    }
  }
  // Atom: <link rel="enclosure" type="audio/*" href="…">
  for (final lk in _allLocal(el.descendantElements, 'link')) {
    if (lk.getAttribute('rel') != 'enclosure') continue;
    final u = lk.getAttribute('href') ?? '';
    final t = lk.getAttribute('type') ?? '';
    if (u.isNotEmpty && (t.startsWith('audio/') || _isAudioUrl(u))) {
      return Enclosure(url: u, type: t);
    }
  }
  return null;
}

/// Parses an RSS 2.0 / Atom / Media-RSS document into typed models.
/// Throws [FeedParseException] on oversized input (M19) or invalid XML.
ParsedFeed parseRssFeed(String xml, String feedUrl) {
  if (xml.length > maxXmlBytes) {
    throw const FeedParseException('Feed is too large to parse safely.');
  }
  XmlDocument d;
  try {
    d = XmlDocument.parse(xml);
  } catch (_) {
    throw const FeedParseException(
        'Not valid XML — check the URL is an RSS or Atom feed.');
  }

  final items = <FeedItem>[];

  // RSS 2.0
  for (final item in _allLocal(d.descendantElements, 'item')) {
    final linkEl = _firstLocal(item.descendantElements, 'link');
    var link = linkEl?.innerText.trim() ?? '';
    if (link.isEmpty) link = linkEl?.getAttribute('href') ?? '';
    var rawDesc =
        _firstLocal(item.descendantElements, 'description')?.innerText ?? '';
    if (rawDesc.isEmpty) rawDesc = _nsText(item, 'encoded');
    if (rawDesc.isEmpty) rawDesc = _nsText(item, 'summary');
    final ch = _findChapters(item);
    items.add(FeedItem(
      title: decodeHtmlEntities(
          (_firstLocal(item.descendantElements, 'title')?.innerText ?? '')
              .trim()),
      link: link,
      date: _firstLocal(item.descendantElements, 'pubDate')?.innerText ?? '',
      desc: _cleanDesc(rawDesc),
      enclosure: _findAudio(item),
      chapters: ch.chapters,
      chaptersUrl: ch.chaptersUrl,
    ));
  }

  // Atom (donor: only when no RSS items were found)
  if (items.isEmpty) {
    for (final entry in _allLocal(d.descendantElements, 'entry')) {
      final links = _allLocal(entry.descendantElements, 'link').toList();
      XmlElement? linkEl;
      for (final l in links) {
        if (l.getAttribute('rel') == 'alternate') {
          linkEl = l;
          break;
        }
      }
      linkEl ??= links.isEmpty ? null : links.first;
      var date =
          _firstLocal(entry.descendantElements, 'published')?.innerText ?? '';
      if (date.isEmpty) {
        date =
            _firstLocal(entry.descendantElements, 'updated')?.innerText ?? '';
      }
      var rawDesc =
          _firstLocal(entry.descendantElements, 'summary')?.innerText ?? '';
      if (rawDesc.isEmpty) {
        rawDesc =
            _firstLocal(entry.descendantElements, 'content')?.innerText ?? '';
      }
      final ch = _findChapters(entry);
      items.add(FeedItem(
        title: decodeHtmlEntities(
            (_firstLocal(entry.descendantElements, 'title')?.innerText ?? '')
                .trim()),
        link: linkEl?.getAttribute('href') ?? '',
        date: date,
        desc: _cleanDesc(rawDesc),
        enclosure: _findAudio(entry),
        chapters: ch.chapters,
        chaptersUrl: ch.chaptersUrl,
      ));
    }
  }

  // channel > title, feed > title — first in document order.
  var feedTitle = '';
  for (final t in _allLocal(d.descendantElements, 'title')) {
    final p = t.parent;
    if (p is XmlElement &&
        (p.name.local == 'channel' || p.name.local == 'feed')) {
      feedTitle = decodeHtmlEntities(t.innerText.trim());
      break;
    }
  }
  if (feedTitle.isEmpty) feedTitle = feedUrl;

  final nextPage = _findNextPage(d, feedUrl);

  return ParsedFeed(
      title: feedTitle,
      items: items,
      nextPageUrl: nextPage.url,
      nextPageRel: nextPage.rel);
}

/// Common named HTML entities (the full HTML5 table has ~2200; feeds in the
/// wild overwhelmingly use these).
const Map<String, String> _namedEntities = {
  'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'",
  'nbsp': ' ', 'shy': '­',
  'copy': '©', 'reg': '®', 'trade': '™', 'deg': '°', 'plusmn': '±',
  'middot': '·', 'bull': '•', 'hellip': '…',
  'ndash': '–', 'mdash': '—', 'minus': '−',
  'lsquo': '‘', 'rsquo': '’', 'sbquo': '‚',
  'ldquo': '“', 'rdquo': '”', 'bdquo': '„',
  'laquo': '«', 'raquo': '»',
  'times': '×', 'divide': '÷', 'sect': '§', 'para': '¶',
  'dagger': '†', 'Dagger': '‡', 'permil': '‰',
  'prime': '′', 'Prime': '″',
  'euro': '€', 'pound': '£', 'yen': '¥', 'cent': '¢', 'curren': '¤',
  'iexcl': '¡', 'iquest': '¿', 'micro': 'µ', 'not': '¬',
  'frac12': '½', 'frac14': '¼', 'frac34': '¾',
  'sup1': '¹', 'sup2': '²', 'sup3': '³', 'ordf': 'ª', 'ordm': 'º',
  'larr': '←', 'uarr': '↑', 'rarr': '→', 'darr': '↓', 'harr': '↔',
  'infin': '∞', 'ne': '≠', 'le': '≤', 'ge': '≥',
  'ensp': ' ', 'emsp': ' ', 'thinsp': ' ',
  'zwnj': '‌', 'zwj': '‍', 'lrm': '‎', 'rlm': '‏',
  'fnof': 'ƒ', 'circ': 'ˆ', 'tilde': '˜',
  'oelig': 'œ', 'OElig': 'Œ', 'scaron': 'š', 'Scaron': 'Š', 'Yuml': 'Ÿ',
  'szlig': 'ß', 'eth': 'ð', 'thorn': 'þ', 'ETH': 'Ð', 'THORN': 'Þ',
  'agrave': 'à', 'aacute': 'á', 'acirc': 'â', 'atilde': 'ã', 'auml': 'ä',
  'aring': 'å', 'aelig': 'æ', 'ccedil': 'ç',
  'egrave': 'è', 'eacute': 'é', 'ecirc': 'ê', 'euml': 'ë',
  'igrave': 'ì', 'iacute': 'í', 'icirc': 'î', 'iuml': 'ï',
  'ntilde': 'ñ', 'ograve': 'ò', 'oacute': 'ó', 'ocirc': 'ô', 'otilde': 'õ',
  'ouml': 'ö', 'oslash': 'ø',
  'ugrave': 'ù', 'uacute': 'ú', 'ucirc': 'û', 'uuml': 'ü',
  'yacute': 'ý', 'yuml': 'ÿ',
  'Agrave': 'À', 'Aacute': 'Á', 'Acirc': 'Â', 'Atilde': 'Ã', 'Auml': 'Ä',
  'Aring': 'Å', 'AElig': 'Æ', 'Ccedil': 'Ç',
  'Egrave': 'È', 'Eacute': 'É', 'Ecirc': 'Ê', 'Euml': 'Ë',
  'Igrave': 'Ì', 'Iacute': 'Í', 'Icirc': 'Î', 'Iuml': 'Ï',
  'Ntilde': 'Ñ', 'Ograve': 'Ò', 'Oacute': 'Ó', 'Ocirc': 'Ô', 'Otilde': 'Õ',
  'Ouml': 'Ö', 'Oslash': 'Ø',
  'Ugrave': 'Ù', 'Uacute': 'Ú', 'Ucirc': 'Û', 'Uuml': 'Ü', 'Yacute': 'Ý',
};
