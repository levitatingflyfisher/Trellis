/// Typed feed models — the donor kept plain objects
/// ({title, link, date, desc, audio, chapters?, chaptersUrl?}).
library;

/// A chosen audio enclosure. The donor kept only the URL; the MIME type
/// (possibly empty) rides along here.
class Enclosure {
  const Enclosure({required this.url, this.type = ''});

  final String url;
  final String type;

  @override
  bool operator ==(Object other) =>
      other is Enclosure && other.url == url && other.type == type;

  @override
  int get hashCode => Object.hash(url, type);

  @override
  String toString() => 'Enclosure($url, $type)';
}

/// One chapter mark (Podlove simple chapters / podcast:chapters inline).
class FeedChapter {
  const FeedChapter({
    required this.start,
    this.title = '',
    this.href = '',
    this.image = '',
  });

  /// Seconds. May be NaN when the feed's timestamp was unparseable
  /// (donor quirk kept: `Number(...)` propagates NaN for H:M:S forms).
  final double start;
  final String title;
  final String href;
  final String image;
}

class FeedItem {
  const FeedItem({
    required this.title,
    required this.link,
    required this.date,
    required this.desc,
    this.enclosure,
    this.chapters,
    this.chaptersUrl,
    this.contentHtml,
  });

  final String title;
  final String link;

  /// The raw date string from the feed (pubDate / published / updated) —
  /// the donor never parsed it at this layer.
  final String date;

  /// Entity-decoded, tag-stripped, 300-char-capped description — always
  /// this length or shorter, list-display material only.
  final String desc;

  /// The item's own full HTML body — RSS `content:encoded` or Atom
  /// `content` — raw and UNCAPPED (Campaign 9 Phase 4, "the feed becomes
  /// honest reading"). Null when the feed offers no such element, which
  /// most podcast feeds don't; never the empty string. Read regardless of
  /// whether [desc] already came from the SAME element (a feed with no
  /// `description` at all) — ingestion decides what to do with each
  /// independently.
  final String? contentHtml;

  final Enclosure? enclosure;

  /// Donor-compatible accessor: the audio URL or ''.
  String get audio => enclosure?.url ?? '';

  /// Inline chapters, when the item carried them.
  final List<FeedChapter>? chapters;

  /// External chapters document URL (podcast:chapters url form).
  final String? chaptersUrl;
}

class ParsedFeed {
  const ParsedFeed(
      {required this.title,
      required this.items,
      this.nextPageUrl,
      this.nextPageRel,
      this.imageUrl});

  /// Channel/feed title, falling back to the feed URL.
  final String title;
  final List<FeedItem> items;

  /// The older archive page's URL (RFC 5005), resolved against the feed's
  /// own URL — from a channel/feed-level `<atom:link rel="next">` or, when
  /// that is absent, `rel="prev-archive"`. Null when the host publishes
  /// neither, which is the overwhelmingly common case.
  final String? nextPageUrl;

  /// Which relation produced [nextPageUrl] — `'next'` or `'prev-archive'`
  /// — or null when there is none.
  final String? nextPageRel;

  /// Channel-level artwork (P6 "the river gets faces"): `itunes:image
  /// href`, falling back to RSS's own `<image><url>`. Resolved against the
  /// feed's URL the same way [nextPageUrl] is. Null when the host publishes
  /// neither, which the calm river layout treats as "no thumbnail" rather
  /// than an error.
  final String? imageUrl;
}
