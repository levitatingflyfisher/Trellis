// Gutendex (gutendex.com) search client: URL building, result mapping on a
// real-shaped fixture, and the fetched-book → paragraph pipeline
// (boilerplate strip + hard-wrap unwrap + blank-line paragraph law).
import 'dart:convert';

import 'package:intake_core/intake_core.dart';
import 'package:test/test.dart';

/// Real-shaped Gutendex `/books?search=` response (fields and nesting as the
/// live API returns them; values shortened).
final _fixture = jsonEncode({
  'count': 132,
  'next': 'https://gutendex.com/books/?page=2&search=austen',
  'previous': null,
  'results': [
    {
      'id': 1342,
      'title': 'Pride and Prejudice',
      'authors': [
        {'name': 'Austen, Jane', 'birth_year': 1775, 'death_year': 1817}
      ],
      'translators': [],
      'subjects': ['Courtship -- Fiction', 'England -- Fiction'],
      'bookshelves': ['Best Books Ever Listings'],
      'languages': ['en'],
      'copyright': false,
      'media_type': 'Text',
      'formats': {
        'text/html': 'https://www.gutenberg.org/ebooks/1342.html.images',
        'application/epub+zip':
            'https://www.gutenberg.org/ebooks/1342.epub3.images',
        'text/plain; charset=us-ascii':
            'https://www.gutenberg.org/files/1342/1342-0.txt',
        'application/octet-stream':
            'https://www.gutenberg.org/files/1342/1342-0.zip',
      },
      'download_count': 51155,
    },
    {
      'id': 84,
      'title': 'Frankenstein; Or, The Modern Prometheus',
      'authors': [
        {
          'name': 'Shelley, Mary Wollstonecraft',
          'birth_year': 1797,
          'death_year': 1851
        }
      ],
      'translators': [],
      'subjects': ['Science fiction'],
      'bookshelves': [],
      'languages': ['en', 'fr'],
      'copyright': false,
      'media_type': 'Text',
      'formats': {
        'text/html; charset=utf-8':
            'https://www.gutenberg.org/files/84/84-h/84-h.htm',
        'application/epub+zip': 'https://www.gutenberg.org/ebooks/84.epub',
      },
      'download_count': 104123,
    },
    {
      'id': 999,
      'title': 'Audio Only Curiosity',
      'authors': <Map<String, Object?>>[],
      'translators': [],
      'subjects': [],
      'bookshelves': [],
      'languages': ['en'],
      'copyright': null,
      'media_type': 'Sound',
      'formats': {'audio/mpeg': 'https://www.gutenberg.org/files/999/999.mp3'},
      'download_count': 7,
    },
  ],
});

void main() {
  group('buildGutendexSearchUrl', () {
    test('targets gutendex.com/books with the query as ?search=', () {
      final u = buildGutendexSearchUrl('pride prejudice');
      expect(u.scheme, 'https');
      expect(u.host, 'gutendex.com');
      expect(u.path, '/books');
      expect(u.queryParameters['search'], 'pride prejudice');
    });

    test('query is encoded on the wire (a literal & cannot split params)', () {
      final u = buildGutendexSearchUrl('krig & fred');
      expect(u.query, isNot(contains('& ')));
      expect(u.query, contains('%26'));
      expect(u.queryParameters['search'], 'krig & fred',
          reason: 'round-trips losslessly');
    });
  });

  group('parseGutendexPage', () {
    test('maps count, next and every result field the UI shows', () {
      final page = parseGutendexPage(_fixture);
      expect(page.count, 132);
      expect(page.nextUrl, 'https://gutendex.com/books/?page=2&search=austen');
      expect(page.books, hasLength(3));

      final pride = page.books[0];
      expect(pride.id, 1342);
      expect(pride.title, 'Pride and Prejudice');
      expect(pride.authors, ['Austen, Jane']);
      expect(pride.languages, ['en']);
      expect(pride.downloadCount, 51155);
      expect(pride.textUrl, 'https://www.gutenberg.org/files/1342/1342-0.txt');
      expect(
          pride.htmlUrl, 'https://www.gutenberg.org/ebooks/1342.html.images');
      expect(pride.importUrl, pride.textUrl,
          reason: 'plain text wins over html when both exist');
      expect(pride.importIsHtml, isFalse);
    });

    test('an html-only edition imports through its html URL', () {
      final frank = parseGutendexPage(_fixture).books[1];
      expect(frank.textUrl, isNull);
      expect(frank.htmlUrl, 'https://www.gutenberg.org/files/84/84-h/84-h.htm');
      expect(frank.importUrl, frank.htmlUrl);
      expect(frank.importIsHtml, isTrue);
      expect(frank.languages, ['en', 'fr']);
    });

    test('a book with no readable edition has no import URL', () {
      final audio = parseGutendexPage(_fixture).books[2];
      expect(audio.textUrl, isNull);
      expect(audio.htmlUrl, isNull);
      expect(audio.importUrl, isNull);
    });

    test('a zip pretending to be text/html is not an import URL', () {
      final page = parseGutendexPage(jsonEncode({
        'count': 1,
        'next': null,
        'results': [
          {
            'id': 1,
            'title': 'Zipped',
            'authors': <Map<String, Object?>>[],
            'languages': ['en'],
            'formats': {
              'text/html': 'https://www.gutenberg.org/files/1/1-h.zip'
            },
            'download_count': 1,
          }
        ],
      }));
      expect(page.books.single.htmlUrl, isNull);
    });

    test('a last page has no next URL', () {
      final page = parseGutendexPage(
          jsonEncode({'count': 1, 'next': null, 'results': <Object?>[]}));
      expect(page.nextUrl, isNull);
      expect(page.books, isEmpty);
    });

    test('malformed JSON or a shape without results throws FormatException',
        () {
      expect(() => parseGutendexPage('not json'),
          throwsA(isA<FormatException>()));
      expect(() => parseGutendexPage('{"answer": 42}'),
          throwsA(isA<FormatException>()));
      expect(() => parseGutendexPage('[1,2,3]'),
          throwsA(isA<FormatException>()));
    });
  });

  group('gutenbergParagraphs (fetched book → spine paragraphs)', () {
    test('plain text: markers stripped, wrap undone, blank line = paragraph',
        () {
      const raw = 'The Project Gutenberg eBook of Example\n'
          'License preamble here.\n'
          '*** START OF THE PROJECT GUTENBERG EBOOK EXAMPLE ***\n'
          'It is a truth universally\nacknowledged, that a single\n'
          'man in possession of a good\nfortune, must be in want of a wife.\n'
          '\n'
          'However little known the\nfeelings or views of such a man.\n'
          '\n*** END OF THE PROJECT GUTENBERG EBOOK EXAMPLE ***\n'
          'License trailer.';
      expect(gutenbergParagraphs(raw), [
        'It is a truth universally acknowledged, that a single man in '
            'possession of a good fortune, must be in want of a wife.',
        'However little known the feelings or views of such a man.',
      ]);
    });

    test('several blank lines are still ONE paragraph break', () {
      expect(gutenbergParagraphs('One.\n\n\n\nTwo.'), ['One.', 'Two.']);
    });

    test('html edition: block tags become paragraphs, markers stripped, '
        'entities decoded, script/style dropped', () {
      const html = '<html><head><title>x</title>'
          '<style>p { color: inherit; }</style></head><body>'
          '<p>*** START OF THE PROJECT GUTENBERG EBOOK EXAMPLE ***</p>'
          '<h1>Chapter I.</h1>'
          '<p>It is a truth &amp; a jest,\nuniversally acknowledged.</p>'
          '<script>alert(1)</script>'
          '<p>A second paragraph.</p>'
          '<p>*** END OF THE PROJECT GUTENBERG EBOOK EXAMPLE ***</p>'
          '<p>Trailer.</p></body></html>';
      expect(gutenbergParagraphs(html, isHtml: true), [
        'Chapter I.',
        'It is a truth & a jest, universally acknowledged.',
        'A second paragraph.',
      ]);
    });

    test('whitespace-only input yields no paragraphs', () {
      expect(gutenbergParagraphs('   \n\n  '), isEmpty);
      expect(gutenbergParagraphs('<body>  </body>', isHtml: true), isEmpty);
    });
  });
}
