// Port tests for donor `stripGutenbergBoilerplate` and `gutPickTextUrl`
// (ohPrimer index.html ~3471-3486). The donor JS is the spec.
import 'package:intake_core/intake_core.dart';
import 'package:test/test.dart';

void main() {
  group('stripGutenbergBoilerplate (donor stripGutenbergBoilerplate)', () {
    test('cuts everything through the *** START OF ... *** line', () {
      const raw = 'The Project Gutenberg eBook of Example\n'
          'Some license preamble.\n'
          '*** START OF THE PROJECT GUTENBERG EBOOK EXAMPLE ***\n'
          'Actual text begins.';
      expect(stripGutenbergBoilerplate(raw), 'Actual text begins.');
    });

    test('start marker with trailing junk after *** is consumed to newline',
        () {
      const raw = '*** START OF THIS PROJECT GUTENBERG EBOOK *** produced by X\n'
          'Body.';
      expect(stripGutenbergBoilerplate(raw), 'Body.');
    });

    test('cuts everything from the *** END OF ... *** marker on', () {
      const raw = 'Body text.\n'
          '\n*** END OF THE PROJECT GUTENBERG EBOOK EXAMPLE ***\n'
          'License trailer here.';
      expect(stripGutenbergBoilerplate(raw), 'Body text.');
    });

    test('markers are case-insensitive', () {
      const raw = '*** Start of the Project Gutenberg eBook ***\n'
          'Body.\n'
          '\n*** end of the project gutenberg ebook ***';
      expect(stripGutenbergBoilerplate(raw), 'Body.');
    });

    test('unwraps single newlines (~72-col prose wrap) to spaces', () {
      const raw = 'It is a truth universally\nacknowledged, that a single\n'
          'man in possession of a good\nfortune, must be in want of a wife.';
      expect(
          stripGutenbergBoilerplate(raw),
          'It is a truth universally acknowledged, that a single '
          'man in possession of a good fortune, must be in want of a wife.');
    });

    test('blank lines (paragraph breaks) survive the unwrap', () {
      const raw = 'Para one line A\nPara one line B\n\nPara two.';
      expect(stripGutenbergBoilerplate(raw),
          'Para one line A Para one line B\n\nPara two.');
    });

    test('text without markers is just unwrapped and trimmed', () {
      expect(stripGutenbergBoilerplate('  hello\nworld  '), 'hello world');
    });

    // "Be liberal in what you accept": older PG files vary the marker shape.
    test('a START line missing its closing *** is still cut', () {
      const raw = 'Preamble.\n'
          '*** START OF THE PROJECT GUTENBERG EBOOK FRANKENSTEIN\n'
          'Body.';
      expect(stripGutenbergBoilerplate(raw), 'Body.');
    });

    test('an END line missing its closing *** is still cut', () {
      const raw = 'Body.\n'
          '\n*** END OF THE PROJECT GUTENBERG EBOOK FRANKENSTEIN\n'
          'Trailer.';
      expect(stripGutenbergBoilerplate(raw), 'Body.');
    });

    test('markers indented or with only two asterisks are still cut', () {
      const raw = '  ** START OF THE PROJECT GUTENBERG EBOOK X\n'
          'Body.\n'
          '\n  ** END OF THE PROJECT GUTENBERG EBOOK X';
      expect(stripGutenbergBoilerplate(raw), 'Body.');
    });
  });

  group('pickGutenbergTextUrl (donor gutPickTextUrl)', () {
    test('prefers utf-8, then us-ascii, then bare text/plain', () {
      final formats = {
        'text/html': 'http://x/h',
        'text/plain': 'http://x/p',
        'text/plain; charset=us-ascii': 'http://x/a',
        'text/plain; charset=utf-8': 'http://x/u',
      };
      expect(pickGutenbergTextUrl(formats), 'http://x/u');
      formats.remove('text/plain; charset=utf-8');
      expect(pickGutenbergTextUrl(formats), 'http://x/a');
      formats.remove('text/plain; charset=us-ascii');
      expect(pickGutenbergTextUrl(formats), 'http://x/p');
    });

    test('falls back to any text/plain-prefixed key', () {
      expect(
          pickGutenbergTextUrl({
            'application/epub+zip': 'http://x/e',
            'text/plain; charset=iso-8859-1': 'http://x/l',
          }),
          'http://x/l');
    });

    test('null when no plain-text format exists', () {
      expect(pickGutenbergTextUrl({'text/html': 'http://x/h'}), isNull);
      expect(pickGutenbergTextUrl({}), isNull);
    });
  });
}
