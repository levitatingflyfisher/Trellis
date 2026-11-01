import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:study_core/study_core.dart' as study;
import 'package:trellis/features/study/card_editing.dart';

/// Making and editing a card by hand (owner, 28 Oct: "have we fixed the
/// flashcard mechanics for highlighting and writing stuff and editing it
/// reasonable?"). A card is an item in the course's own text, so every
/// change here is a new course text that study_core's strict parser
/// accepts; nothing about scheduling changes.
void main() {
  String ladder() => json.encode({
        'schemaVersion': '1.0',
        'id': 'ladder',
        'title': 'A Ladder',
        'provenance': {'by': 'someone'},
        'nodes': [
          {
            'id': 'a',
            'title': 'Foundation',
            'intake': 'Water is wet.',
            'items': [
              {
                'id': 'i-a',
                'type': 'cloze',
                'rung': 1,
                'text': 'Water is {{c1::wet}}.',
                'answers': {'c1': 'wet'},
                'hints': ['Think of rain.'],
                'sources': ['The sea'],
              },
              {
                'id': 'i-b',
                'type': 'qa',
                'rung': 3,
                'prompt': 'Why?',
                'answer': 'Because.',
                'acceptable': ['because'],
              },
            ],
          },
          {
            'id': 'b',
            'title': 'Next',
            'prereqs': ['a'],
            'intake': 'More.',
            'items': [
              {
                'id': 'i-c',
                'type': 'qa',
                'rung': 3,
                'prompt': 'What next?',
                'answer': 'This.',
              },
            ],
          },
        ],
      });

  study.RetrievalItem itemOf(String raw, String id) => study
      .parseCourseString(raw)
      .nodes
      .expand((n) => n.items)
      .firstWhere((i) => i.id == id);

  group('cloze, written the Anki way', () {
    test('each {{cN::answer}} is a blank, and its number is its key', () {
      expect(clozeAnswersOf('{{c1::Paris}} is the capital of {{c2::France}}.'),
          {'c1': 'Paris', 'c2': 'France'});
    });

    test('a hint after a second :: is not part of the answer', () {
      expect(clozeAnswersOf('{{c1::Paris::a city}} is lovely.'),
          {'c1': 'Paris'});
    });

    test('the same number twice is one blank asked twice', () {
      expect(clozeAnswersOf('{{c1::state}} in, {{c1::state}} out.'),
          {'c1': 'state'});
    });

    test('text with no blank, an empty blank, or one number with two '
        'answers is refused in plain words', () {
      for (final bad in [
        'No blank here.',
        'An {{c1::}} empty one.',
        '{{c1::one}} and {{c1::two}}.',
      ]) {
        expect(() => clozeAnswersOf(bad), throwsFormatException, reason: bad);
      }
      expect(
          () => clozeAnswersOf('No blank here.'),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              contains('{{c1::'))));
    });

    test('blanking a selection takes the next free number', () {
      const text = 'Water is wet and cold.';
      final once = blankSelection(text, 9, 12);
      expect(once, 'Water is {{c1::wet}} and cold.');
      final start = once.indexOf('cold');
      expect(blankSelection(once, start, start + 4),
          'Water is {{c1::wet}} and {{c2::cold}}.');
      expect(blankSelection(text, 5, 5), text,
          reason: 'nothing selected, nothing changes');
    });

    test('a word held in the reader becomes the blank in its sentence', () {
      expect(clozeFromSentence('Hola, amigo mío.', 'amigo'),
          'Hola, {{c1::amigo}} mío.');
      expect(clozeFromSentence('The cat sat on the category.', 'cat'),
          'The {{c1::cat}} sat on the category.',
          reason: 'the word itself, not the start of a longer word');
      expect(clozeFromSentence('今日はカレーです。', 'カレー'),
          '今日は{{c1::カレー}}です。',
          reason: 'Japanese has no spaces between words');
    });
  });

  group('adding', () {
    test('a front-and-back card joins its step, and nothing else in the '
        'course changes', () {
      final raw = courseWithNewCard(ladder(),
          nodeId: 'b',
          itemId: 'card-1',
          draft: const CardDraft.frontBack('Capital of France?', 'Paris'));
      final item = itemOf(raw, 'card-1') as study.QaItem;
      expect(item.prompt, 'Capital of France?');
      expect(item.answer, 'Paris');
      final decoded = json.decode(raw) as Map<String, dynamic>;
      expect(decoded['provenance'], {'by': 'someone'},
          reason: 'what the parser ignores is kept');
      expect(study.parseCourseString(raw).nodeById('b')!.items.map((i) => i.id),
          ['i-c', 'card-1']);
      expect(itemOf(raw, 'i-a'), isA<study.ClozeItem>());
    });

    test('a cloze card is a cloze item with its answers', () {
      final raw = courseWithNewCard(ladder(),
          nodeId: 'a',
          itemId: 'card-2',
          draft: const CardDraft.cloze('{{c1::Ice}} is cold.'));
      final item = itemOf(raw, 'card-2') as study.ClozeItem;
      expect(item.text, '{{c1::Ice}} is cold.');
      expect(item.answers, {'c1': 'Ice'});
      expect(item.rung, 1);
    });

    test('an empty front or back is refused', () {
      expect(
          () => courseWithNewCard(ladder(),
              nodeId: 'a',
              itemId: 'x',
              draft: const CardDraft.frontBack('  ', 'Paris')),
          throwsFormatException);
      expect(
          () => courseWithNewCard(ladder(),
              nodeId: 'a',
              itemId: 'x',
              draft: const CardDraft.frontBack('Q', '')),
          throwsFormatException);
    });

    test('a new id never repeats one the course has', () {
      expect(newCardId({'card-5'}, 5), 'card-5-2');
      expect(newCardId({}, 5), 'card-5');
    });

    test('My cards is a course of its own, made with its first card, with '
        'no reading before the cards', () {
      final raw = newMyCardsCourse(
          itemId: 'card-1', draft: const CardDraft.cloze('{{c1::Hola}}.'));
      final course = study.parseCourseString(raw);
      expect(course.id, myCardsCourseId);
      expect(course.title, 'My cards');
      expect(course.nodes.single.intake, isEmpty);
      expect(course.nodes.single.items.single, isA<study.ClozeItem>());
    });
  });

  group('editing', () {
    test('a card keeps its id (so its history), its hints and sources', () {
      final raw = courseWithEditedCard(
          ladder(), 'i-a', const CardDraft.cloze('Water is {{c1::damp}}.'));
      final item = itemOf(raw, 'i-a') as study.ClozeItem;
      expect(item.answers, {'c1': 'damp'});
      expect(item.hints, ['Think of rain.']);
      expect(item.sources, ['The sea']);
    });

    test('a front-and-back card can become a cloze, and back', () {
      final cloze = courseWithEditedCard(
          ladder(), 'i-b', const CardDraft.cloze('{{c1::Because}} it is.'));
      expect(itemOf(cloze, 'i-b'), isA<study.ClozeItem>());
      final back = courseWithEditedCard(
          cloze, 'i-b', const CardDraft.frontBack('Why?', 'Because.'));
      expect((itemOf(back, 'i-b') as study.QaItem).answer, 'Because.');
    });

    test('an edited answer drops the old answer’s keywords', () {
      final raw = courseWithEditedCard(
          ladder(), 'i-b', const CardDraft.frontBack('Why?', 'For a reason.'));
      expect((itemOf(raw, 'i-b') as study.QaItem).acceptable, isEmpty);
    });

    test('a card reads back as the draft it was made from', () {
      expect(draftOf(itemOf(ladder(), 'i-a')),
          const CardDraft.cloze('Water is {{c1::wet}}.'));
      expect(draftOf(itemOf(ladder(), 'i-b')),
          const CardDraft.frontBack('Why?', 'Because.'));
    });

    test('deleting takes a card out of its step, but never a step’s last '
        'card', () {
      final raw = courseWithoutCard(ladder(), 'i-b');
      expect(study.parseCourseString(raw).nodeById('a')!.items.map((i) => i.id),
          ['i-a']);
      expect(() => courseWithoutCard(ladder(), 'i-c'), throwsStateError);
    });
  });

  // Pictures on cards (owner, 28 Oct): a draft carries its picture's
  // name, and the course text names it on the item.
  group('pictures', () {
    test('a new card names its picture', () {
      final raw = courseWithNewCard(ladder(),
          nodeId: 'a',
          itemId: 'card-1',
          draft: const CardDraft.frontBack('What bird?', 'A heron.',
              image: 'heron.png'));
      expect(itemOf(raw, 'card-1').image, 'heron.png');
      final cloze = courseWithNewCard(ladder(),
          nodeId: 'a',
          itemId: 'card-2',
          draft: const CardDraft.cloze('A {{c1::heron}}.', image: 'h.jpg'));
      expect(itemOf(cloze, 'card-2').image, 'h.jpg');
    });

    test('an edit keeps, changes or takes off the picture, as the draft '
        'says', () {
      final named = courseWithEditedCard(ladder(), 'i-b',
          const CardDraft.frontBack('Why?', 'Because.', image: 'a.png'));
      expect(itemOf(named, 'i-b').image, 'a.png');
      expect(draftOf(itemOf(named, 'i-b')),
          const CardDraft.frontBack('Why?', 'Because.', image: 'a.png'));
      final off = courseWithEditedCard(
          named, 'i-b', const CardDraft.frontBack('Why?', 'Because.'));
      expect(itemOf(off, 'i-b').image, isNull);
      expect((json.decode(off) as Map).toString(), isNot(contains('a.png')));
    });

    test('a draft with a different picture is a different draft', () {
      expect(const CardDraft.cloze('{{c1::x}}', image: 'a.png'),
          isNot(const CardDraft.cloze('{{c1::x}}')));
      expect(const CardDraft.cloze('{{c1::x}}').withImage('b.png').image,
          'b.png');
      expect(const CardDraft.frontBack('f', 'b', image: 'b.png')
          .withImage(null), const CardDraft.frontBack('f', 'b'));
    });
  });
}

