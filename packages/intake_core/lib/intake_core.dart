/// Document intake for PrimingTrellis — EPUB, article-by-URL, Gutenberg text.
///
/// Ported from ohPrimer's `index.html` (the donor JS is the spec). Pure Dart:
/// bytes and strings in, plain typed block structures out. No HTTP happens
/// here — the caller fetches; this package parses.
library;

export 'src/article_extractor.dart';
export 'src/audiobook_ordering.dart';
export 'src/blocks.dart';
export 'src/charset.dart';
export 'src/epub_parser.dart';
export 'src/gutenberg_cleaner.dart';
export 'src/gutendex.dart';
export 'src/m4b_chapters.dart';
