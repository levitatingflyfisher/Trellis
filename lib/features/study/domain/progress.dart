import '../../curriculum/domain/models.dart';

/// Per-node study state derived from card states. A brand-new item (no card
/// yet) counts as due; an item is "mastered" once its interval reaches a
/// threshold (durable enough to count as learned).
class NodeProgress {
  const NodeProgress({
    required this.total,
    required this.due,
    required this.mastered,
  });
  final int total;
  final int due;
  final int mastered;

  double get mastery => total == 0 ? 0 : mastered / total;
  bool get hasDue => due > 0;
}

NodeProgress nodeProgress(
  KnowledgeNode node,
  Map<String, CardState> cards,
  int todayEpochDay, {
  int masteryIntervalDays = 7,
}) {
  var due = 0;
  var mastered = 0;
  for (final item in node.items) {
    final c = cards[item.id];
    if (c == null) {
      due++; // never seen = due to learn
      continue;
    }
    if (c.isDue(todayEpochDay)) due++;
    if (c.intervalDays >= masteryIntervalDays) mastered++;
  }
  return NodeProgress(total: node.items.length, due: due, mastered: mastered);
}

/// A node is unlocked once all its prerequisite nodes are fully mastered.
bool nodeUnlocked(
  KnowledgeNode node,
  Course course,
  Map<String, CardState> cards,
  int todayEpochDay,
) {
  for (final pid in node.prereqs) {
    final p = course.nodeById(pid);
    if (p == null) continue;
    if (nodeProgress(p, cards, todayEpochDay).mastery < 1.0) return false;
  }
  return true;
}

/// Same as [nodeUnlocked] but reads prerequisite mastery from a precomputed
/// `nodeId -> NodeProgress` map, so a screen that already built progress for
/// every node doesn't recompute it per prerequisite on each rebuild.
bool nodeUnlockedFrom(KnowledgeNode node, Map<String, NodeProgress> progressByNode) {
  for (final pid in node.prereqs) {
    final p = progressByNode[pid];
    if (p == null) continue;
    if (p.mastery < 1.0) return false;
  }
  return true;
}
