import 'package:flutter_test/flutter_test.dart';
import 'package:loom_core/loom_core.dart';
import 'package:trellis/features/reader/reader_logic.dart';

/// Frozen references: a saved article's link is a character range of its
/// segment's text. The reader shows words, so each range is turned into
/// the words it covers, using the tokenizer's own output.
void main() {
  Map<int, String> linked(String text, List<(int, int, String)> links) {
    final doc = tokenizeDocument([
      Segment(idx: 0, kind: SegmentKind.prose, text: 'Before.'),
      Segment(idx: 1, kind: SegmentKind.prose, text: text),
    ]);
    final start = doc.blockStartWordIdx[1];
    return linkedWordsOf(
        text: text,
        originals: doc.originals.sublist(start),
        firstWordIdx: start,
        links: links);
  }

  (int, int, String) at(String text, String words, String href) {
    final s = text.indexOf(words);
    return (s, s + words.length, href);
  }

  test('each word inside a link points to it, numbered across the document',
      () {
    const t = 'See the first study for more.';
    expect(linked(t, [at(t, 'the first study', 'https://a.test/')]), {
      2: 'https://a.test/',
      3: 'https://a.test/',
      4: 'https://a.test/',
    });
  });

  test('a word touching a link by its punctuation is in it', () {
    const t = 'Read (this page), then stop.';
    expect(linked(t, [at(t, 'this page', 'https://p.test/')]).keys, [2, 3]);
  });

  test('a repeated word is matched at its own place', () {
    const t = 'the cat and the dog';
    expect(linked(t, [(12, 19, 'https://d.test/')]).keys, [4, 5]);
  });

  test('every part of a split compound follows the compound', () {
    const t = 'a well-known-story told twice';
    expect(linked(t, [at(t, 'known', 'https://k.test/')]).keys, [2, 3, 4]);
    expect(linked(t, [at(t, 'told', 'https://t.test/')]).keys, [5]);
  });

  test('two compounds in a row keep their own places', () {
    const t = 'well-known well-known end';
    expect(
        linked(t, [(11, 21, 'https://s.test/')]).keys, [3, 4],
        reason: 'only the second compound');
  });

  test('a shortened address word is matched by its full text', () {
    const t = 'at https://example.org/a/very/long/path/to/a/page now';
    expect(linked(t, [at(t, 'now', 'https://n.test/')]).keys, [3]);
  });

  test('no links, no linked words; a range off the text is ignored', () {
    expect(linked('plain words', const []), isEmpty);
    expect(linked('plain words', [(50, 60, 'https://x.test/')]), isEmpty);
  });
}
