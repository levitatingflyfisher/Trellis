/// The plain typed content blocks every intake parser emits.
///
/// These mirror the donor's flat block objects (`{type:"text"|"segment",...}`
/// in ohPrimer `index.html`) without importing loom_core — the integrator maps
/// them onto the app's spine types.
library;

/// A parsed content block.
sealed class IntakeBlock {
  const IntakeBlock();
}

/// A link inside a [TextBlock]: the words `text.substring(start, end)` point
/// to [href], an absolute http or https address (frozen references, owner
/// ask of 21 and 24 Oct 2026).
final class TextLink {
  final int start;
  final int end;
  final String href;
  const TextLink({required this.start, required this.end, required this.href});

  @override
  bool operator ==(Object other) =>
      other is TextLink &&
      other.start == start &&
      other.end == end &&
      other.href == href;

  @override
  int get hashCode => Object.hash(start, end, href);

  @override
  String toString() => 'TextLink($start, $end, $href)';
}

/// A run of prose (donor `{type:"text",text}`). Whitespace already collapsed.
final class TextBlock extends IntakeBlock {
  final String text;

  /// Its web links, in text order, never overlapping. Only the article
  /// extractor fills these; every other parser leaves them empty.
  final List<TextLink> links;
  const TextBlock(this.text, {this.links = const []});

  @override
  String toString() => 'TextBlock($text)';
}

/// An image reference (donor `{type:"segment",kind:"figure",content:{src,alt}}`).
///
/// [src] is resolved relative to the OPF root directory; it is the key into
/// `EpubDoc.images`.
final class FigureBlock extends IntakeBlock {
  final String src;
  final String alt;
  const FigureBlock({required this.src, required this.alt});

  @override
  String toString() => 'FigureBlock($src)';
}

/// The non-prose segment kinds the donor distinguishes.
enum IntakeSegmentKind { code, table, math }

/// A captured non-prose segment (donor `{type:"segment",kind,content}` for
/// code/table/math): the raw text content of the element, untokenized.
final class SegmentBlock extends IntakeBlock {
  final IntakeSegmentKind kind;
  final String content;
  const SegmentBlock({required this.kind, required this.content});

  @override
  String toString() => 'SegmentBlock(${kind.name})';
}
