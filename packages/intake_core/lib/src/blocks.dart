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

/// A run of prose (donor `{type:"text",text}`). Whitespace already collapsed.
final class TextBlock extends IntakeBlock {
  final String text;
  const TextBlock(this.text);

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
