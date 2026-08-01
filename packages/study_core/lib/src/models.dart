// Immutable domain models for a Trellis course (the .ohcourse format).
// Pure data: no JSON (see CurriculumParser) and no persistence here.

enum ItemType { cloze, qa, discrimination, procedure }

/// A single retrieval item. `rung` (1..4) ≈ H(answer|cue): how much the learner
/// must generate from memory. 1 = high-cue (cloze), 4 = free generation.
sealed class RetrievalItem {
  const RetrievalItem({
    required this.id,
    required this.rung,
    this.hints = const [],
    this.sources = const [],
  });
  final String id;
  final int rung;
  final List<String> hints;
  final List<String> sources;
  ItemType get type;
}

class ClozeItem extends RetrievalItem {
  const ClozeItem({
    required super.id,
    required super.rung,
    super.hints,
    super.sources,
    required this.text,
    required this.answers,
  });

  /// Text containing `{{cN::answer}}` blanks.
  final String text;

  /// Blank key (`c1`, `c2`, ...) -> expected answer.
  final Map<String, String> answers;

  @override
  ItemType get type => ItemType.cloze;
}

class QaItem extends RetrievalItem {
  const QaItem({
    required super.id,
    required super.rung,
    super.hints,
    super.sources,
    required this.prompt,
    required this.answer,
    this.acceptable = const [],
    this.rubric,
  });
  final String prompt;
  final String answer;

  /// Keyword anchors for lenient auto-grading of a typed response.
  final List<String> acceptable;
  final String? rubric;

  @override
  ItemType get type => ItemType.qa;
}

class DiscriminationItem extends RetrievalItem {
  const DiscriminationItem({
    required super.id,
    required super.rung,
    super.hints,
    super.sources,
    required this.prompt,
    required this.choices,
    required this.correctIndex,
    this.explanation,
  });
  final String prompt;
  final List<String> choices;
  final int correctIndex;
  final String? explanation;

  @override
  ItemType get type => ItemType.discrimination;
}

class ProcedureItem extends RetrievalItem {
  const ProcedureItem({
    required super.id,
    required super.rung,
    super.hints,
    super.sources,
    required this.prompt,
    required this.steps,
    this.rubric,
  });
  final String prompt;
  final List<String> steps;
  final String? rubric;

  @override
  ItemType get type => ItemType.procedure;
}

class KnowledgeNode {
  const KnowledgeNode({
    required this.id,
    required this.title,
    this.summary = '',
    this.prereqs = const [],
    this.diagramMermaid,
    required this.intake,
    required this.items,
  });
  final String id;
  final String title;
  final String summary;
  final List<String> prereqs;
  final String? diagramMermaid;
  final String intake;
  final List<RetrievalItem> items;
}

class SrsDefaults {
  const SrsDefaults({
    this.algorithm = 'sm2',
    this.initialEase = 2.5,
    this.firstIntervalDays = 1,
  });
  final String algorithm;
  final double initialEase;
  final int firstIntervalDays;
}

class Course {
  const Course({
    required this.id,
    required this.title,
    this.subtitle = '',
    this.subject = '',
    this.level = '',
    this.description = '',
    this.srsDefaults = const SrsDefaults(),
    required this.nodes,
  });
  final String id;
  final String title;
  final String subtitle;
  final String subject;
  final String level;
  final String description;
  final SrsDefaults srsDefaults;
  final List<KnowledgeNode> nodes;

  KnowledgeNode? nodeById(String id) {
    for (final n in nodes) {
      if (n.id == id) return n;
    }
    return null;
  }
}

/// Learner self-rating after a retrieval attempt; drives the SM-2 scheduler.
enum Grade { again, hard, good, easy }

/// Per-item spaced-repetition state. `dueEpochDay` / scheduling are in whole
/// days since the Unix epoch (UTC), so the app is timezone-stable and testable.
class CardState {
  const CardState({
    required this.itemId,
    required this.ease,
    required this.intervalDays,
    required this.dueEpochDay,
    required this.reps,
    required this.lapses,
  });

  final String itemId;
  final double ease;
  final int intervalDays;
  final int dueEpochDay;
  final int reps;
  final int lapses;

  factory CardState.initial(String itemId, SrsDefaults d, int todayEpochDay) =>
      CardState(
        itemId: itemId,
        ease: d.initialEase,
        intervalDays: 0,
        dueEpochDay: todayEpochDay,
        reps: 0,
        lapses: 0,
      );

  bool isDue(int todayEpochDay) => dueEpochDay <= todayEpochDay;

  CardState copyWith({
    double? ease,
    int? intervalDays,
    int? dueEpochDay,
    int? reps,
    int? lapses,
  }) =>
      CardState(
        itemId: itemId,
        ease: ease ?? this.ease,
        intervalDays: intervalDays ?? this.intervalDays,
        dueEpochDay: dueEpochDay ?? this.dueEpochDay,
        reps: reps ?? this.reps,
        lapses: lapses ?? this.lapses,
      );
}
