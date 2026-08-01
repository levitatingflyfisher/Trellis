/// Distill-time discourse: each course node carries 1-2 `discourse`
/// items — a Socratic follow-up and/or an explain-back prompt — baked
/// into the `.ohcourse` JSON itself. That is the ADR-0001 adoption
/// posture: construction-and-discourse study works on zero-ML devices,
/// because the prompts travel with the course instead of needing a
/// Brain at study time.
///
/// study_core's strict parser deliberately ignores keys it does not
/// know, so `discourse` rides the same file without touching the donor
/// semantics ("the tests are the spec"). This module is the reader and
/// the validator for that key.
library;

/// The two discourse moves (Dunlosky's elaborative-interrogation tier).
enum DiscourseKind {
  /// A Socratic follow-up probing one gap ("What would break if…?").
  socratic,

  /// A teach-it-back prompt ("Explain X in your own words.").
  explainBack,
}

const Map<String, DiscourseKind> _kindByWire = {
  'socratic': DiscourseKind.socratic,
  'explain_back': DiscourseKind.explainBack,
};

/// The wire name for [kind] inside `.ohcourse` JSON.
String discourseKindWireName(DiscourseKind kind) => switch (kind) {
      DiscourseKind.socratic => 'socratic',
      DiscourseKind.explainBack => 'explain_back',
    };

/// One baked-in discourse prompt.
class DiscourseItem {
  const DiscourseItem({required this.kind, required this.prompt});

  final DiscourseKind kind;
  final String prompt;

  @override
  bool operator ==(Object other) =>
      other is DiscourseItem && other.kind == kind && other.prompt == prompt;

  @override
  int get hashCode => Object.hash(kind, prompt);

  @override
  String toString() => 'DiscourseItem(${kind.name}: $prompt)';
}

/// Reads the discourse map (node id → items) out of a decoded `.ohcourse`
/// object. Lenient the way the house parsers are lenient: a node without
/// a `discourse` key simply has none (older/foreign courses stay
/// importable), but a *present* malformed entry throws a path-qualified
/// [FormatException] rather than being silently dropped.
Map<String, List<DiscourseItem>> readCourseDiscourse(
    Map<String, dynamic> courseJson) {
  final result = <String, List<DiscourseItem>>{};
  final rawNodes = courseJson['nodes'];
  if (rawNodes is! List) return result;

  for (var i = 0; i < rawNodes.length; i++) {
    final node = rawNodes[i];
    if (node is! Map<String, dynamic>) continue;
    final nodeId = node['id'] is String ? node['id'] as String : '#$i';
    final raw = node['discourse'];
    if (raw == null) continue;
    result[nodeId] = _parseItems(raw, nodeId);
  }
  return result;
}

/// The distiller's side of the invariant: a *generated* course must give
/// every node 1-2 well-formed discourse items, kinds not repeated. Runs
/// against the same decoded JSON that already passed the strict
/// `parseCourse`, and
/// throws path-qualified [FormatException]s shaped like the strict
/// parser's own, so repair rounds can feed them straight back.
void validateDistilledDiscourse(Map<String, dynamic> courseJson) {
  final rawNodes = courseJson['nodes'];
  if (rawNodes is! List) {
    throw const FormatException("course: 'nodes' must be a list");
  }
  for (var i = 0; i < rawNodes.length; i++) {
    final node = rawNodes[i];
    if (node is! Map<String, dynamic>) {
      throw FormatException('course: nodes[$i] must be an object');
    }
    final nodeId = node['id'] is String ? node['id'] as String : '#$i';
    final raw = node['discourse'];
    if (raw == null) {
      throw FormatException(
          "node '$nodeId': missing required 'discourse' (1-2 items)");
    }
    final items = _parseItems(raw, nodeId);
    if (items.isEmpty || items.length > 2) {
      throw FormatException(
        "node '$nodeId': 'discourse' must have 1-2 items "
        '(found ${items.length})',
      );
    }
    if (items.length == 2 && items[0].kind == items[1].kind) {
      throw FormatException(
        "node '$nodeId': 'discourse' repeats kind "
        "'${discourseKindWireName(items[0].kind)}' — pair a Socratic "
        'follow-up with an explain-back prompt instead',
      );
    }
  }
}

List<DiscourseItem> _parseItems(Object raw, String nodeId) {
  if (raw is! List) {
    throw FormatException("node '$nodeId': 'discourse' must be a list");
  }
  final items = <DiscourseItem>[];
  for (var i = 0; i < raw.length; i++) {
    final entry = raw[i];
    final where = "node '$nodeId' discourse[$i]";
    if (entry is! Map<String, dynamic>) {
      throw FormatException('$where: must be an object');
    }
    final kindRaw = entry['kind'];
    if (kindRaw is! String) {
      throw FormatException("$where: missing required 'kind'");
    }
    final kind = _kindByWire[kindRaw];
    if (kind == null) {
      throw FormatException(
        "$where: unknown kind '$kindRaw' "
        '(expected one of: ${_kindByWire.keys.join(', ')})',
      );
    }
    final prompt = entry['prompt'];
    if (prompt is! String || prompt.trim().isEmpty) {
      throw FormatException(
          "$where: 'prompt' must be a non-empty string");
    }
    items.add(DiscourseItem(kind: kind, prompt: prompt));
  }
  return items;
}
