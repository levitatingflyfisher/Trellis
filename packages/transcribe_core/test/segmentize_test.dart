import 'package:ml_runtime/ml_runtime.dart';
import 'package:test/test.dart';
import 'package:transcribe_core/transcribe_core.dart';

TranscriptChunk chunk(String text, int t0, int t1) =>
    TranscriptChunk(text: text, tStartMs: t0, tEndMs: t1);

void main() {
  group('sentence splitting', () {
    test('splits on ASCII enders followed by whitespace', () {
      final segs = segmentize(
        [chunk('Hello there. How are you? Fine!', 0, 3000)],
        minChars: 1,
      );
      expect(segs.map((s) => s.text),
          ['Hello there.', 'How are you?', 'Fine!']);
    });

    test('a dot inside a number is not a sentence end', () {
      final segs = segmentize(
        [chunk('Pi is 3.14 roughly.', 0, 2000)],
        minChars: 1,
      );
      expect(segs.map((s) => s.text), ['Pi is 3.14 roughly.']);
    });

    test('runs of enders stay together', () {
      final segs = segmentize(
        [chunk('Really?! Yes... maybe. Sure.', 0, 2000)],
        minChars: 1,
      );
      expect(segs.map((s) => s.text), ['Really?!', 'Yes... maybe.', 'Sure.']);
    });

    test('a closing quote after the ender stays with its sentence', () {
      final segs = segmentize(
        [chunk('"Stop!" he said.', 0, 2000)],
        minChars: 1,
      );
      expect(segs.map((s) => s.text), ['"Stop!"', 'he said.']);
    });

    test('Spanish inverted marks: ¿ opens the question it belongs to', () {
      final segs = segmentize(
        [chunk('Hola. ¿Cómo estás? Muy bien.', 0, 3000)],
        minChars: 1,
      );
      expect(segs.map((s) => s.text), ['Hola.', '¿Cómo estás?', 'Muy bien.']);
    });

    test('CJK full stops split without any following space', () {
      final segs = segmentize(
        [chunk('你好。我很好。真的！', 0, 3000)],
        minChars: 1,
      );
      expect(segs.map((s) => s.text), ['你好。', '我很好。', '真的！']);
    });

    test('an ellipsis mid-thought does not split without whitespace', () {
      final segs = segmentize(
        [chunk('Wait…what? Ok.', 0, 2000)],
        minChars: 1,
      );
      expect(segs.map((s) => s.text), ['Wait…what?', 'Ok.']);
    });

    test('text without any ender is one segment', () {
      final segs = segmentize(
        [chunk('an unfinished thought', 0, 1000)],
        minChars: 1,
      );
      expect(segs.map((s) => s.text), ['an unfinished thought']);
    });
  });

  group('chunk boundaries', () {
    test('a sentence spanning two chunks becomes one segment', () {
      final segs = segmentize(
        [chunk('Hello', 0, 1000), chunk('world.', 1000, 2000)],
        minChars: 1,
      );
      expect(segs.map((s) => s.text), ['Hello world.']);
      expect(segs.single.tStartMs, 0);
      expect(segs.single.tEndMs, 2000);
    });

    test('chunk texts are trimmed before joining', () {
      final segs = segmentize(
        [chunk(' Hello ', 0, 1000), chunk(' world. ', 1000, 2000)],
        minChars: 1,
      );
      expect(segs.map((s) => s.text), ['Hello world.']);
    });

    test('empty and whitespace-only chunks vanish', () {
      final segs = segmentize(
        [
          chunk('', 0, 500),
          chunk('One.', 500, 1000),
          chunk('   ', 1000, 1200),
          chunk('Two.', 1200, 2000),
        ],
        minChars: 1,
      );
      expect(segs.map((s) => s.text), ['One.', 'Two.']);
    });

    test('empty input yields no segments', () {
      expect(segmentize([]), isEmpty);
      expect(segmentize([chunk('   ', 0, 100)]), isEmpty);
    });
  });

  group('length bounds', () {
    test('too-short sentences merge forward until minChars is met', () {
      final segs = segmentize(
        [chunk('No. Way. This is a longer sentence.', 0, 4000)],
        minChars: 8,
      );
      expect(segs.map((s) => s.text), ['No. Way.', 'This is a longer sentence.']);
    });

    test('a too-short tail merges backward into the previous segment', () {
      final segs = segmentize(
        [chunk('A quite long first sentence. Ok.', 0, 3000)],
        minChars: 8,
      );
      expect(segs.map((s) => s.text), ['A quite long first sentence. Ok.']);
    });

    test('a lone too-short sentence survives', () {
      final segs = segmentize([chunk('Hi.', 0, 500)], minChars: 8);
      expect(segs.map((s) => s.text), ['Hi.']);
    });

    test('over-long runs split at whitespace within maxChars', () {
      final segs = segmentize(
        [chunk('one two three four five six seven', 0, 7000)],
        minChars: 1,
        maxChars: 12,
      );
      for (final s in segs) {
        expect(s.text.length, lessThanOrEqualTo(12));
        expect(s.text, isNot(startsWith(' ')));
        expect(s.text, isNot(endsWith(' ')));
      }
      expect(segs.map((s) => s.text).join(' '),
          'one two three four five six seven');
    });

    test('an unbreakable over-long run is hard-cut at maxChars', () {
      final segs = segmentize(
        [chunk('abcdefghijklmnop', 0, 1000)],
        minChars: 1,
        maxChars: 6,
      );
      expect(segs.map((s) => s.text), ['abcdef', 'ghijkl', 'mnop']);
    });
  });

  group('times', () {
    test('segments carry ascending, non-overlapping spans over the audio', () {
      final segs = segmentize(
        [
          chunk('First sentence here. Second one.', 0, 4000),
          chunk('Third arrives now. And a fourth!', 4000, 8000),
        ],
        minChars: 1,
      );
      expect(segs, hasLength(4));
      expect(segs.first.tStartMs, 0);
      expect(segs.last.tEndMs, 8000);
      for (var i = 0; i < segs.length; i++) {
        expect(segs[i].tEndMs, greaterThan(segs[i].tStartMs));
        if (i > 0) {
          expect(segs[i].tStartMs,
              greaterThanOrEqualTo(segs[i - 1].tEndMs));
        }
      }
    });

    test('a segment inside one chunk interpolates within that chunk', () {
      final segs = segmentize(
        [chunk('aaaa. bbbb.', 0, 1100)],
        minChars: 1,
      );
      expect(segs, hasLength(2));
      // 'aaaa.' spans chars 0..5 of 11 -> ends by half of the chunk.
      expect(segs[0].tStartMs, 0);
      expect(segs[0].tEndMs, lessThanOrEqualTo(550));
      // 'bbbb.' starts past half and runs to the chunk end.
      expect(segs[1].tStartMs, greaterThanOrEqualTo(550));
      expect(segs[1].tEndMs, 1100);
    });
  });

  group('bounds validation', () {
    test('rejects nonsense bounds', () {
      expect(() => segmentize([], minChars: 0), throwsArgumentError);
      expect(() => segmentize([], maxChars: 0), throwsArgumentError);
      expect(() => segmentize([], minChars: 20, maxChars: 10),
          throwsArgumentError);
    });
  });
}
