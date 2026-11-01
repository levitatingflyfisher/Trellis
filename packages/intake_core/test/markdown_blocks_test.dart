import 'package:intake_core/intake_core.dart';
import 'package:test/test.dart';

/// Markdown files as reading text (owner, 1.6.x: "tried to open a markdown
/// file in Trellis and could not"). Headings become chapters, links stay
/// links, lists and tables read well, and no markup is left for the page
/// to show or the voice to say.
void main() {
  List<(String, String)> blocks(String md) => [
        for (final b in parseMarkdown(md).blocks) (b.kind.name, b.text),
      ];

  group('headings and paragraphs', () {
    test('hash headings are headings; lines of a paragraph join', () {
      expect(blocks('''
# The Harbour

The harbour was quiet
that morning.

## The Fog ##

It came in overnight.
'''), [
        ('heading', 'The Harbour'),
        ('prose', 'The harbour was quiet that morning.'),
        ('heading', 'The Fog'),
        ('prose', 'It came in overnight.'),
      ]);
    });

    test('underlined headings are headings too', () {
      expect(blocks('The Harbour\n===========\n\nText.\n\nThe Fog\n-------\n\nMore.'), [
        ('heading', 'The Harbour'),
        ('prose', 'Text.'),
        ('heading', 'The Fog'),
        ('prose', 'More.'),
      ]);
    });

    test('a heading knows its level', () {
      final doc = parseMarkdown('# One\n\n### Three');
      expect([for (final b in doc.blocks) b.level], [1, 3]);
    });

    test('a rule between paragraphs is dropped, and still parts them', () {
      expect(blocks('Before.\n\n---\n\nAfter.\n***\nLast.'), [
        ('prose', 'Before.'),
        ('prose', 'After.'),
        ('prose', 'Last.'),
      ]);
    });
  });

  group('markup inside a line', () {
    test('bold, italics, strike and code marks go; their words stay', () {
      expect(blocks('It was **very** quiet, _almost_ ~~silent~~ still, '
          'said `harbour_master`.'), [
        ('prose', 'It was very quiet, almost silent still, said harbour_master.'),
      ]);
    });

    test('underscores inside a word, and escaped marks, are left alone', () {
      expect(blocks(r'The file snake_case_name.txt costs 5 \* 3, not \_this\_.'), [
        ('prose', 'The file snake_case_name.txt costs 5 * 3, not _this_.'),
      ]);
    });

    test('a link keeps its words and its address', () {
      expect(blocks('See the [tide tables](https://example.org/tides "Tides") '
          'first.'), [
        ('prose', 'See the tide tables https://example.org/tides first.'),
      ]);
    });

    test('a link that is only an address is written once', () {
      expect(
          blocks('Go to <https://example.org/a> or '
              '[https://example.org/b](https://example.org/b).'),
          [('prose', 'Go to https://example.org/a or https://example.org/b.')]);
    });

    test('a reference link is looked up, and its definition is not text',
        () {
      expect(blocks('Read [the guide][g] today.\n\n[g]: https://example.org/g "Guide"'), [
        ('prose', 'Read the guide https://example.org/g today.'),
      ]);
    });

    test('a picture leaves its description', () {
      expect(blocks('![A boat at dawn](boat.png) on the water.'),
          [('prose', 'A boat at dawn on the water.')]);
    });

    test('html tags and comments go', () {
      expect(blocks('Line one<br>line two <!-- hidden --> <span>kept</span>.'),
          [('prose', 'Line one line two kept.')]);
    });

    test('a footnote mark goes; its note stays as a line of its own', () {
      expect(blocks('Fees matter.[^1]\n\n[^1]: Bogle, 2007.'), [
        ('prose', 'Fees matter.'),
        ('prose', 'Note: Bogle, 2007.'),
      ]);
    });
  });

  group('lists', () {
    test('each item is a line of its own, with a plain mark', () {
      expect(blocks('Bring:\n\n- a coat\n- a **warm** hat\n* gloves\n'), [
        ('prose', 'Bring:'),
        ('prose', '• a coat'),
        ('prose', '• a warm hat'),
        ('prose', '• gloves'),
      ]);
    });

    test('numbered items keep their numbers', () {
      expect(blocks('1. Cast off.\n2. Row out.\n10) Come back.'), [
        ('prose', '1) Cast off.'),
        ('prose', '2) Row out.'),
        ('prose', '10) Come back.'),
      ]);
    });

    test('an item that runs on, and items inside items, stay whole', () {
      expect(blocks('- first line\n  carries on\n  - inside\n- second'), [
        ('prose', '• first line carries on'),
        ('prose', '• inside'),
        ('prose', '• second'),
      ]);
    });

    test('a task list says what is done', () {
      expect(blocks('- [ ] buy rope\n- [x] mend net'), [
        ('prose', '• buy rope'),
        ('prose', '• mend net (done)'),
      ]);
    });
  });

  group('quotes, code and tables', () {
    test('a quote is its words', () {
      expect(blocks('> The sea is patient.\n> It waits.\n\nSo they say.'), [
        ('prose', 'The sea is patient. It waits.'),
        ('prose', 'So they say.'),
      ]);
    });

    test('fenced code is kept as code, exactly, and is not read as text',
        () {
      expect(blocks('Run:\n\n```sh\nmake *all*\n  ./go\n```\n\nDone.'), [
        ('prose', 'Run:'),
        ('code', 'make *all*\n  ./go'),
        ('prose', 'Done.'),
      ]);
    });

    test('a table becomes one readable line for each row', () {
      expect(blocks('''
| Port | High tide | Low |
|------|:---------:|----:|
| Hull | 06:10 | 12:30 |
| Wick | 07:45 | |
'''), [
        ('prose', 'Port: Hull; High tide: 06:10; Low: 12:30.'),
        ('prose', 'Port: Wick; High tide: 07:45.'),
      ]);
    });

    test('pipes in ordinary text are not a table', () {
      expect(blocks('Use a | b to pipe.'), [('prose', 'Use a | b to pipe.')]);
    });
  });

  group('the title', () {
    test('is the front matter’s, and the front matter is not text', () {
      final doc = parseMarkdown(
          '---\ntitle: "Harbour Days"\nauthor: A\n---\n\n# Chapter one\n\nText.',
          sourceName: 'x.md');
      expect(doc.title, 'Harbour Days');
      expect([for (final b in doc.blocks) b.text], ['Chapter one', 'Text.']);
    });

    test('else the first top heading, else the first heading', () {
      expect(parseMarkdown('Intro.\n\n## Part\n\n# The Book').title, 'The Book');
      expect(parseMarkdown('## Only part\n\nText.').title, 'Only part');
    });

    test('else the file’s name without its ending, else a plain word', () {
      expect(parseMarkdown('Just text.', sourceName: 'Tide notes.md').title,
          'Tide notes');
      expect(parseMarkdown('Just text.').title, 'Untitled');
    });
  });

  test('windows line ends, a byte-order mark and blank files are handled',
      () {
    expect(blocks('﻿# Title\r\n\r\nText one\r\ntext two.\r\n'), [
      ('heading', 'Title'),
      ('prose', 'Text one text two.'),
    ]);
    expect(parseMarkdown('   \n\n').blocks, isEmpty);
  });
}
