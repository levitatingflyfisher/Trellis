import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/reader/speech/pocket/pocket_text.dart';

/// Kyutai's `prepare_text_prompt` (pocket_tts/models/text_chunking.py),
/// ported: what the model is given for one sentence.
void main() {
  PocketPrompt de(String t) => preparePocketText(t, PocketLanguage.german);

  test('German drops quotes and brackets, turns dashes and semicolons '
      'into commas, and capitalises the first letter', () {
    expect(de('„hallo“ (sagte er) – wirklich; ja').text,
        'Hallo sagte er , wirklich, ja.');
  });

  test('a sentence mark followed by a stray comma keeps the mark only', () {
    expect(de('„Wirklich?“, fragte sie.').text, 'Wirklich? fragte sie.');
  });

  test('terminal punctuation: kept, added, or a weak mark replaced', () {
    expect(de('Gut.').text, 'Gut.');
    expect(de('Gut!').text, 'Gut!');
    expect(de('Gut…').text, 'Gut…');
    expect(de('Gut').text, 'Gut.');
    expect(de('Gut,').text, 'Gut.');
    expect(de('Gut -').text, 'Gut.');
    expect(preparePocketText('Bien:', PocketLanguage.spanish).text, 'Bien.');
  });

  test('a closing quote after the full stop is left alone; one after a '
      'word gets the full stop after it', () {
    final en = PocketLanguage.english;
    expect(preparePocketText('He said "stop."', en).text, 'He said "stop."');
    expect(preparePocketText('He said "stop"', en).text, 'He said "stop".');
  });

  test('English keeps straight quotes but turns curly apostrophes '
      'straight, and keeps semicolons', () {
    expect(preparePocketText('it’s fine; ok', PocketLanguage.english).text,
        "It's fine; ok.");
  });

  test('Spanish drops the opening ¿ and ¡', () {
    expect(preparePocketText('¿Qué tal?', PocketLanguage.spanish).text,
        'Qué tal?');
  });

  test('French turns a colon into a comma', () {
    expect(preparePocketText('voici : la suite',
                PocketLanguage.french)
            .text,
        'Voici , la suite.');
  });

  test('newlines and runs of space collapse', () {
    expect(de('eins\nzwei   drei').text, 'Eins zwei drei.');
  });

  test('extra frames after the end: 3 for four words or fewer, else 1', () {
    expect(de('Ein zwei drei vier.').framesAfterEos, 3);
    expect(de('Ein zwei drei vier fünf.').framesAfterEos, 1);
  });

  test('a letter outside ASCII is capitalised too', () {
    expect(de('über alles').text, 'Über alles.');
  });

  test('a first letter whose capital is two letters is capitalised as '
      'Python does (Unicode special casing)', () {
    expect(de('ßeltsam').text, 'SSeltsam.');
    expect(preparePocketText('ﬁne', PocketLanguage.english).text, 'FIne.');
  });

  test('empty text is refused', () {
    expect(() => de('   '), throwsArgumentError);
    expect(() => de('„“'), throwsArgumentError);
  });

  test('each language is known by its tag', () {
    expect(PocketLanguage.byTag('de'), PocketLanguage.german);
    expect(PocketLanguage.byTag('pt'), PocketLanguage.portuguese);
    expect(PocketLanguage.byTag('nl'), PocketLanguage.dutch);
    expect(PocketLanguage.byTag('ru'), isNull);
  });
}
