import 'package:test/test.dart';
import 'package:study_core/src/models.dart';
import 'package:study_core/src/progress.dart';
import 'package:study_core/src/sm2_scheduler.dart';

/// Two concepts in a chain: `b` requires `a`.
const _course = Course(
  id: 'c',
  title: 'C',
  nodes: [
    KnowledgeNode(
      id: 'a',
      title: 'A',
      intake: 'i',
      items: [
        QaItem(id: 'a1', rung: 1, prompt: 'p', answer: 'x'),
        QaItem(id: 'a2', rung: 1, prompt: 'q', answer: 'y'),
      ],
    ),
    KnowledgeNode(
      id: 'b',
      title: 'B',
      intake: 'i',
      prereqs: ['a'],
      items: [QaItem(id: 'b1', rung: 1, prompt: 'r', answer: 'z')],
    ),
  ],
);

void main() {
  test('a concept that has unlocked never locks again while you keep passing',
      () {
    // Unlocking reads current intervals, so anything that shrinks an interval
    // can take a concept away again. Rating "Hard" — an honest self-rating on
    // a *successful* recall — used to do exactly that: intervals climbed to
    // the 7-day mastery threshold, then decayed back down, re-locking work the
    // learner had already earned and stranding the rest of the course behind
    // a gate that could no longer be passed.
    final nodeA = _course.nodes.first;
    final nodeB = _course.nodes.last;
    final cards = <String, CardState>{};
    var day = 0;
    var everUnlocked = false;

    for (var review = 0; review < 30; review++) {
      for (final item in nodeA.items) {
        final c = cards[item.id] ?? CardState.initial(item.id, const SrsDefaults(), day);
        cards[item.id] = scheduleSm2(c, Grade.hard, day);
      }
      day = nodeA.items
          .map((it) => cards[it.id]!.dueEpochDay)
          .reduce((a, b) => a > b ? a : b);

      final unlocked = nodeUnlocked(nodeB, _course, cards, day);
      if (unlocked) everUnlocked = true;
      expect(
        !everUnlocked || unlocked,
        isTrue,
        reason: 'concept "b" unlocked and then locked again at review $review '
            '— intervals: ${nodeA.items.map((it) => cards[it.id]!.intervalDays).toList()}',
      );
    }

    expect(everUnlocked, isTrue,
        reason: 'thirty successful recalls must be enough to open the next '
            'concept, whatever the learner rated them');
  });
}
