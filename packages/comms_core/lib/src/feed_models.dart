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
  });

  final String title;
  final String link;

  /// The raw date string from the feed (pubDate / published / updated) —
  /// the donor never parsed it at this layer.
  final String date;

  /// Entity-decoded, tag-stripped, 300-char-capped description.
  final String desc;

  final Enclosure? enclosure;

  /// Donor-compatible accessor: the audio URL or ''.
  String get audio => enclosure?.url ?? '';

  /// Inline chapters, when the item carried them.
  final List<FeedChapter>? chapters;

  /// External chapters document URL (podcast:chapters url form).
  final String? chaptersUrl;
}

class ParsedFeed {
  const ParsedFeed({required this.title, required this.items});

  /// Channel/feed title, falling back to the feed URL.
  final String title;
  final List<FeedItem> items;
}
