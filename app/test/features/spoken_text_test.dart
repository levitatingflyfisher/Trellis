import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/reader/speech/spoken_text.dart';

/// What read aloud leaves unsaid (1.6.0, owner: read aloud "speaks every
/// inline citation in the personal finance book, which makes it painful
/// to listen to"). The page keeps every character; only the voice skips.
void main() {
  group('author and year in round brackets', () {
    test('a plain citation goes, and the full stop closes up', () {
      expect(spokenText('Saving early matters most (Smith, 2019).'),
          'Saving early matters most.');
      expect(spokenText('Costs compound (Bogle 2007) over decades.'),
          'Costs compound over decades.');
    });

    test('several works, lead-ins, pages and letters after the year', () {
      expect(
          spokenText('Fees matter (see Smith & Jones, 2019, pp. 4–9; Lee et '
              'al., 2020a; Federal Reserve, 2021).'),
          'Fees matter.');
      expect(spokenText('It varies (e.g., Malkiel, 1973, ch. 2).'),
          'It varies.');
      expect(spokenText('Others agree (O’Neil and van der Berg, 2015b).'),
          'Others agree.');
    });

    test('a year alone after a name goes too', () {
      expect(spokenText('Kahneman (2011) calls this loss aversion.'),
          'Kahneman calls this loss aversion.');
      expect(spokenText('As Fama and French (1993, p. 12) showed, size '
          'matters.'), 'As Fama and French showed, size matters.');
    });

    test('an aside that only mentions a year is kept', () {
      const aside = 'The fund (which opened in 2019 with two clients) grew.';
      expect(spokenText(aside), aside);
      const money = 'Rates fell (from 5% in 2007 to 0.25% in 2009).';
      expect(spokenText(money), money);
      const plain = 'She paid it off (finally) in March.';
      expect(spokenText(plain), plain);
    });
  });

  group('numbers and keys in square brackets', () {
    test('numbers, lists and ranges go', () {
      expect(spokenText('Index funds win [12].'), 'Index funds win.');
      expect(spokenText('Index funds win [3, 7–9, 14] over time.'),
          'Index funds win over time.');
      expect(spokenText('As shown in [4, p. 12], fees matter.'),
          'As shown in, fees matter.');
    });

    test('keys go', () {
      expect(spokenText('Fees matter [Bog07].'), 'Fees matter.');
      expect(spokenText('Fees matter [SJ+20, Lee19a].'), 'Fees matter.');
      expect(spokenText('Fees matter [@bogle2007].'), 'Fees matter.');
      expect(spokenText('It is contested [citation needed].'),
          'It is contested.');
      expect(spokenText('It began there [a] and spread [note 3].'),
          'It began there and spread.');
    });

    test('an editor’s words in square brackets are kept', () {
      const sic = 'He wrote "their [sic] money" twice.';
      expect(spokenText(sic), sic);
      const added = 'They [the bank] refused.';
      expect(spokenText(added), added);
    });
  });

  group('the forms in the personal finance book', () {
    test('a year after each name in running text', () {
      expect(
          spokenText('Choi (2022), citing Kaplan, Violante and Weidner '
              '(2014), finds many households hold little cash.'),
          'Choi, citing Kaplan, Violante and Weidner, finds many households '
          'hold little cash.');
    });

    test('a bracketed source note, with its link and the day it was read',
        () {
      expect(
          spokenText('The average rate was 6.2% [Freddie Mac PMMS, '
              'https://www.freddiemac.com/pmms, read 2026-11-07].'),
          'The average rate was 6.2%.');
      expect(
          spokenText('[Choi 2022, NBER w30444 p.12, '
              'https://www.nber.org/papers/w30444, read 2026-11-07]'),
          '');
      expect(
          spokenText('He says so [Ramsey Solutions, "Mortgage Loan Dos and '
              'Don’ts," https://www.ramseysolutions.com/x, read '
              '2026-11-07] more than once.'),
          'He says so more than once.');
    });

    test('a source note as long as a paragraph still goes whole', () {
      final title = 'The safe withdrawal rate: evidence from a broad sample '
          'of developed markets, ' * 5;
      expect(
          spokenText('The rate is lower abroad [Anarkulova, Cederburg, '
              'O’Doherty and Sias, "$title" 2025, per the abstract, '
              'https://www.cambridge.org/core/journals/x/article/y/'
              '5D6C1EBBAFE135FC27D236C9F46E677F, read 2026-11-07].'),
          'The rate is lower abroad.');
    });

    test('a note pointing back at the last source', () {
      expect(spokenText('It holds for renters too [same, pp.3-4].'),
          'It holds for renters too.');
      expect(spokenText('It holds [ibid., p. 9].'), 'It holds.');
      expect(spokenText('It holds [Smith 2019].'), 'It holds.');
    });

    test('a work cited through another', () {
      expect(spokenText('Size matters (French 2008, as cited by Choi).'),
          'Size matters.');
      expect(
          spokenText('Debt costs more (Gross and Souleles 2002, as cited by '
              'Choi; the original paper was not opened).'),
          'Debt costs more.');
      expect(
          spokenText('Kaplan (2014, as cited by Choi; original not opened) '
              'agrees.'),
          'Kaplan agrees.');
    });

    test('an aside about where a figure comes from is still said', () {
      const s = 'Balances rose (Federal Reserve data, 2022) again.';
      expect(spokenText(s), s);
    });
  });

  group('footnote marks', () {
    test('raised numbers and the printer’s marks go', () {
      expect(spokenText('Pay yourself first.¹² Then the bills.'),
          'Pay yourself first. Then the bills.');
      expect(spokenText('Pay yourself first† and then the bills‡.'),
          'Pay yourself first and then the bills.');
    });

    test('a number set tight after the punctuation that ends a word goes',
        () {
      expect(spokenText('Pay yourself first.12 Then the bills.'),
          'Pay yourself first. Then the bills.');
      expect(spokenText('He called it “the eighth wonder”,3 and meant it.'),
          'He called it “the eighth wonder”, and meant it.');
    });

    test('real numbers are kept', () {
      const s = 'Rates rose 2.5 points to 7.25 in 2022, a 401k staple.';
      expect(spokenText(s), s);
      const t = 'The S&P 500 fell 3.2% on day 12.';
      expect(spokenText(t), t);
    });
  });

  group('bare links', () {
    test('web addresses and DOIs go', () {
      expect(spokenText('See https://example.org/a/b?c=1 for the table.'),
          'See for the table.');
      expect(spokenText('The form is at www.irs.gov/forms.'),
          'The form is at.');
      expect(spokenText('Published as doi:10.1000/xyz123.'), 'Published as.');
    });
  });

  group('what a Markdown file leaves behind', () {
    test('a link’s address goes, brackets and all; its words are said',
        () {
      expect(spokenText('See the tide tables (https://example.org/tides) '
          'first.'), 'See the tide tables first.');
    });

    test('a list item’s mark is not said', () {
      expect(spokenText('• a warm hat'), 'a warm hat');
      expect(spokenText('• See the tables (https://example.org/t).'),
          'See the tables.');
    });

    test('a numbered item keeps its number', () {
      const s = '2) Row out.';
      expect(spokenText(s), s);
    });
  });

  test('a sentence that was only a citation says nothing', () {
    expect(spokenText('(Smith, 2019).'), '');
    expect(spokenText('[12]'), '');
    expect(spokenText('https://example.org'), '');
  });

  test('text with none of these is left exactly as it is', () {
    const s = 'Spend less than you earn, and invest the rest.';
    expect(spokenText(s), same(s));
  });
}
