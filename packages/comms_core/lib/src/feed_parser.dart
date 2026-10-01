/// parseRssFeed port (donor index.html ~5734) on package:xml.
///
/// Element matching is by LOCAL name in any namespace, which mirrors what
/// the donor's `querySelector`/`getElementsByTagNameNS("*", …)` did in an
/// XML document. package:xml does not require namespace prefixes to be
/// declared, which makes this port slightly more tolerant than DOMParser
/// (a feed with an undeclared `itunes:` prefix parses here, errored there).
library;

import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

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

/// [FeedItem.contentHtml] (Campaign 9 Phase 4): the SAME entity-decode
/// [_cleanDesc] applies (a feed that double-escapes its markup —
/// `&amp;lt;p&amp;gt;` instead of raw `<p>` — must not leave the extractor
/// seeing literal angle brackets as text) but NO tag stripping and NO
/// 300-char cap: the whole point is the full, structured HTML body for
/// ingestion to run through `extractArticle`. Null (never '') for an
/// empty/absent element.
String? _cleanContentHtml(String s) {
  final t = decodeHtmlEntities(s).trim();
  return t.isEmpty ? null : t;
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

/// RFC 5005 archive discovery: a channel/feed-level `<atom:link rel="next">`
/// (or, absent that, `rel="prev-archive"`) among its DIRECT children only —
/// an item/entry carrying the same rel must not leak into the feed level.
/// A relative href is resolved against [feedUrl]; an unresolvable or empty
/// href is treated as absent rather than thrown.
({String? url, String? rel}) _findNextPage(
    XmlElement? container, String feedUrl) {
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

/// Channel-level artwork (P6 "the river gets faces"): the first direct-child
/// `<itunes:image href="…">` (matched by local name, like everything else
/// here), else the first direct-child RSS `<image><url>…</url></image>`.
/// Only the channel/feed root's OWN direct children are considered — an
/// item/entry's own `itunes:image` (episode-specific artwork) must never
/// leak into the feed's image the way [_findNextPage] already guards
/// against an item-level `rel="next"` leaking into the archive link. A
/// relative href resolves against [feedUrl], the same law as
/// [_findNextPage]'s own href resolution.
String? _findChannelImageUrl(XmlElement? container, String feedUrl) {
  if (container == null) return null;
  final imageEls = _allLocal(container.childElements, 'image').toList();
  String? resolve(String href) {
    try {
      return Uri.parse(feedUrl).resolve(href).toString();
    } catch (_) {
      return href;
    }
  }

  for (final img in imageEls) {
    final href = img.getAttribute('href');
    if (href != null && href.isNotEmpty) return resolve(href);
  }
  for (final img in imageEls) {
    final url = _firstLocal(img.childElements, 'url')?.innerText.trim();
    if (url != null && url.isNotEmpty) return resolve(url);
  }
  return null;
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

/// `itunes:duration`: plain seconds, `mm:ss` or `hh:mm:ss`.
int? _parseDuration(String raw) {
  final parts = raw.trim().split(':');
  if (parts.isEmpty || parts.length > 3) return null;
  var seconds = 0;
  for (final p in parts) {
    final n = int.tryParse(p.trim());
    if (n == null || n < 0) return null;
    seconds = seconds * 60 + n;
  }
  return seconds == 0 ? null : seconds * 1000;
}

String? _itemImageUrl(XmlElement item, String feedUrl) {
  for (final img in _allLocal(item.childElements, 'image')) {
    final href = img.getAttribute('href');
    if (href == null || href.trim().isEmpty) continue;
    try {
      return Uri.parse(feedUrl).resolve(href.trim()).toString();
    } catch (_) {
      return href.trim();
    }
  }
  return null;
}

FeedItem _rssItem(XmlElement item, String feedUrl) {
  final linkEl = _firstLocal(item.descendantElements, 'link');
  var link = linkEl?.innerText.trim() ?? '';
  if (link.isEmpty) link = linkEl?.getAttribute('href') ?? '';
  var rawDesc =
      _firstLocal(item.descendantElements, 'description')?.innerText ?? '';
  // content:encoded read unconditionally (Campaign 9 Phase 4) —
  // independent of whether description was present, so a Substack-shaped
  // item (a short excerpt AND a full content:encoded body) keeps both.
  final encoded = _nsText(item, 'encoded');
  if (rawDesc.isEmpty) rawDesc = encoded;
  if (rawDesc.isEmpty) rawDesc = _nsText(item, 'summary');
  final ch = _findChapters(item);
  return FeedItem(
    title: decodeHtmlEntities(
        (_firstLocal(item.descendantElements, 'title')?.innerText ?? '')
            .trim()),
    link: link,
    date: _firstLocal(item.descendantElements, 'pubDate')?.innerText ?? '',
    desc: _cleanDesc(rawDesc),
    enclosure: _findAudio(item),
    chapters: ch.chapters,
    chaptersUrl: ch.chaptersUrl,
    contentHtml: _cleanContentHtml(encoded),
    imageUrl: _itemImageUrl(item, feedUrl),
    durationMs: _parseDuration(_nsText(item, 'duration')),
  );
}

FeedItem _atomEntry(XmlElement entry) {
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
    date = _firstLocal(entry.descendantElements, 'updated')?.innerText ?? '';
  }
  var rawDesc =
      _firstLocal(entry.descendantElements, 'summary')?.innerText ?? '';
  // <content> read unconditionally too (Campaign 9 Phase 4) — same
  // independence from summary as content:encoded's from description above.
  final content =
      _firstLocal(entry.descendantElements, 'content')?.innerText ?? '';
  if (rawDesc.isEmpty) rawDesc = content;
  final ch = _findChapters(entry);
  return FeedItem(
    title: decodeHtmlEntities(
        (_firstLocal(entry.descendantElements, 'title')?.innerText ?? '')
            .trim()),
    link: linkEl?.getAttribute('href') ?? '',
    date: date,
    desc: _cleanDesc(rawDesc),
    enclosure: _findAudio(entry),
    chapters: ch.chapters,
    chaptersUrl: ch.chaptersUrl,
    contentHtml: _cleanContentHtml(content),
  );
}

XmlElement _toElement(List<XmlEvent> events) =>
    const XmlNodeDecoder().convert(events).whereType<XmlElement>().first;

/// Parses an RSS 2.0 / Atom / Media-RSS document into typed models.
/// Throws [FeedParseException] on oversized input (M19) or invalid XML.
///
/// Streams: the document is read as events and only one item (or one
/// channel-level element) is ever built as a tree, then dropped. A whole-
/// document tree costs many times the feed's size, which a 20 MB feed on a
/// cheap phone cannot afford.
ParsedFeed parseRssFeed(String xml, String feedUrl) {
  if (xml.length > maxFeedXmlBytes) {
    throw const FeedParseException('Feed is too large to parse safely.');
  }

  final rssItems = <FeedItem>[];
  final atomItems = <FeedItem>[];
  // The first channel/feed element's own direct children, minus its items:
  // title, artwork and archive links live here and are small.
  final container = XmlElement(XmlName('channel'));
  var containerDepth = -1; // stack depth of the first channel/feed, if open
  var containerSeen = false;

  final open = <String>[]; // local names of the open elements
  List<XmlEvent>? capture;
  var captureDepth = 0;
  String? captureKind; // 'item', 'entry' or 'head'

  void finishCapture() {
    final el = _toElement(capture!);
    switch (captureKind) {
      case 'item':
        rssItems.add(_rssItem(el, feedUrl));
      case 'entry':
        atomItems.add(_atomEntry(el));
      default:
        container.children.add(el);
    }
    capture = null;
    captureKind = null;
  }

  try {
    for (final e in parseEvents(xml,
        validateNesting: true, validateDocument: true)) {
      if (capture != null) {
        capture!.add(e);
        if (e is XmlStartElementEvent && !e.isSelfClosing) {
          open.add(e.localName);
        } else if (e is XmlEndElementEvent) {
          open.removeLast();
          if (open.length == captureDepth) finishCapture();
        }
        continue;
      }
      if (e is XmlStartElementEvent) {
        final local = e.localName;
        final kind = local == 'item' || local == 'entry'
            ? local
            : (containerDepth >= 0 && open.length == containerDepth + 1)
                ? 'head'
                : null;
        if (kind != null) {
          capture = [e];
          captureKind = kind;
          captureDepth = open.length;
          if (e.isSelfClosing) {
            finishCapture();
          } else {
            open.add(local);
          }
          continue;
        }
        if (e.isSelfClosing) continue;
        if (!containerSeen && (local == 'channel' || local == 'feed')) {
          containerSeen = true;
          containerDepth = open.length;
        }
        open.add(local);
      } else if (e is XmlEndElementEvent) {
        open.removeLast();
        if (open.length == containerDepth) containerDepth = -1;
      }
    }
  } on XmlException {
    throw const FeedParseException(
        'Not valid XML. Check the URL is an RSS or Atom feed.');
  }

  // Atom entries count only when no RSS items were found (donor rule).
  final items = rssItems.isNotEmpty ? rssItems : atomItems;

  var feedTitle = '';
  final titleEl = _firstLocal(container.childElements, 'title');
  if (titleEl != null) feedTitle = decodeHtmlEntities(titleEl.innerText.trim());
  if (feedTitle.isEmpty) feedTitle = feedUrl;

  final c = containerSeen ? container : null;
  final nextPage = _findNextPage(c, feedUrl);

  return ParsedFeed(
      title: feedTitle,
      items: items,
      nextPageUrl: nextPage.url,
      nextPageRel: nextPage.rel,
      imageUrl: _findChannelImageUrl(c, feedUrl));
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
