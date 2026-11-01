import 'dart:convert';
import 'dart:math';

import 'package:russian_g2p/russian_g2p.dart';
import 'package:test/test.dart';

const a = '́';

void main() {
  group('a stress table', () {
    final table = RussianStressTable.parse(
        'вода\t1\nгород\t0\nеще\t1\nмолоко\t2\nпривет\t1\n');

    test('knows the words it lists, by their vowel', () {
      expect(table.length, 5);
      expect(table.vowelIndexOf('вода'), 1);
      expect(table.vowelIndexOf('город'), 0);
      expect(table.vowelIndexOf('кошка'), isNull);
    });

    test('looks a word up in lower case, with ё as е', () {
      expect(table.vowelIndexOf('Вода'), 1);
      expect(table.vowelIndexOf('ЕЩЁ'), 1);
    });

    test('marks each word it knows after its stressed vowel', () {
      expect(table.mark('Вода и город.'), 'Вода$a и го${a}род.');
    });

    test('keeps the case of every letter', () {
      expect(table.mark('ПРИВЕТ, Молоко!'), 'ПРИВЕ${a}Т, Молоко$a!');
    });

    test('leaves a word it does not know unmarked', () {
      expect(table.mark('кошка пьёт молоко'), 'кошка пьёт молоко$a');
    });

    test('leaves a word that already has a mark or a ё as it is', () {
      expect(table.mark('во${a}да'), 'во${a}да');
      expect(table.mark('ещё'), 'ещё');
      expect(table.mark('Ещё вода'), 'Ещё вода$a');
    });

    test('leaves text with no Russian in it alone', () {
      expect(table.mark('Hello, 42!'), 'Hello, 42!');
      expect(table.mark(''), '');
    });

    test('a vowel index past the word’s vowels marks nothing', () {
      final odd = RussianStressTable.parse('дом\t3\n');
      expect(odd.mark('дом'), 'дом');
    });

    test('blank lines, comment lines and CRLF endings are read', () {
      final t = RussianStressTable.parse(
          '# from a dictionary\r\nвода\t1\r\n\r\nгород\t0');
      expect(t.length, 2);
      expect(t.vowelIndexOf('город'), 0);
    });

    test('a broken line is refused with its number', () {
      expect(
          () => RussianStressTable.parse('вода\t1\nгород\n'),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('line 2'))));
      expect(
          () => RussianStressTable.parse('вода\tх\n'), throwsFormatException);
    });

    test('an unsorted table reads the same as a sorted one', () {
      final t = RussianStressTable.parse('яблоко\t0\nвода\t1\nарбуз\t1\n');
      expect(t.vowelIndexOf('арбуз'), 1);
      expect(t.vowelIndexOf('вода'), 1);
      expect(t.vowelIndexOf('яблоко'), 0);
    });

    test('the marked text reads through to the phonemes', () {
      expect(sentencePhonemes(table.mark('Привет, вода.')),
          sentencePhonemes('Приве${a}т, вода$a.'));
    });
  });

  group('parse speed', () {
    // About 2 million lines ship; 100k must read in well under a second.
    List<String> words(int n) {
      const letters = 'абвгдежзиклмнопрстуфхцчшщыэюя';
      final rnd = Random(7);
      final seen = <String>{};
      while (seen.length < n) {
        final len = 4 + rnd.nextInt(8);
        seen.add(String.fromCharCodes(List.generate(
            len, (_) => letters.codeUnitAt(rnd.nextInt(letters.length)))));
      }
      return seen.toList();
    }

    final list = words(100000);

    String tableOf(List<String> ws) =>
        ws.map((w) => '$w\t${w.length % 3}').join('\n');

    test('a sorted 100k-line table', () {
      final sorted = [...list]..sort();
      final bytes = utf8.encode(tableOf(sorted));
      final clock = Stopwatch()..start();
      final t = RussianStressTable.fromBytes(bytes);
      clock.stop();
      expect(t.length, 100000);
      expect(t.vowelIndexOf(sorted[12345]), sorted[12345].length % 3);
      expect(clock.elapsedMilliseconds, lessThan(400),
          reason: 'took ${clock.elapsedMilliseconds} ms');
    });

    test('an unsorted 100k-line table', () {
      final bytes = utf8.encode(tableOf(list));
      final clock = Stopwatch()..start();
      final t = RussianStressTable.fromBytes(bytes);
      clock.stop();
      expect(t.length, 100000);
      for (final w in list.take(500)) {
        expect(t.vowelIndexOf(w), w.length % 3);
      }
      expect(clock.elapsedMilliseconds, lessThan(600),
          reason: 'took ${clock.elapsedMilliseconds} ms');
    });
  });
}
