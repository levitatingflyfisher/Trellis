// Parses the `.ohcourse` JSON format (schemaVersion "1.0") into the immutable
// domain graph defined in `../domain/models.dart`.
//
// The parser is *tolerant* of missing OPTIONAL fields (it falls back to the
// model defaults) and *strict* about REQUIRED fields and item `type`s: a
// malformed file throws a [FormatException] with a path-qualified message
// (e.g. "node 'kf-core' item 'kf-1': cloze requires 'text' and 'answers'") so
// the app can refuse a bad import with a clear, traceable error.

import 'dart:convert';

import 'package:trellis/features/curriculum/domain/models.dart';

/// The only schemaVersion this parser accepts.
const String kSupportedSchemaVersion = '1.0';

/// Decodes [jsonText] as JSON and parses it into a [Course].
///
/// Throws [FormatException] if the text is not valid JSON, is not a JSON
/// object, or fails course validation.
Course parseCourseString(String jsonText) {
  final Object? decoded;
  try {
    decoded = json.decode(jsonText);
  } on FormatException catch (e) {
    throw FormatException('invalid JSON: ${e.message}');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException(
      'top-level JSON must be an object (a course)',
    );
  }
  return parseCourse(decoded);
}

/// Parses an already-decoded JSON object into a [Course].
///
/// Throws [FormatException] when a required field is missing/mistyped, the
/// `schemaVersion` is unsupported, or an item declares an unknown `type`.
Course parseCourse(Map<String, dynamic> json) {
  final version = _optString(json, 'schemaVersion');
  if (version == null) {
    throw const FormatException("course: missing required 'schemaVersion'");
  }
  if (version != kSupportedSchemaVersion) {
    throw FormatException(
      "course: unsupported schemaVersion '$version' "
      "(this app supports '$kSupportedSchemaVersion')",
    );
  }

  final id = _reqString(json, 'id', 'course');
  final title = _reqString(json, 'title', 'course');

  final rawNodes = json['nodes'];
  if (rawNodes is! List) {
    throw const FormatException("course: 'nodes' must be a list");
  }
  if (rawNodes.isEmpty) {
    throw const FormatException("course: 'nodes' must not be empty");
  }

  final nodes = <KnowledgeNode>[];
  for (var i = 0; i < rawNodes.length; i++) {
    final raw = rawNodes[i];
    if (raw is! Map<String, dynamic>) {
      throw FormatException('course: nodes[$i] must be an object');
    }
    nodes.add(_parseNode(raw, i));
  }

  // Referential integrity: every prereq must name a real node (a typo or stale
  // id would otherwise silently defeat prerequisite gating).
  final nodeIds = {for (final n in nodes) n.id};
  for (final n in nodes) {
    for (final p in n.prereqs) {
      if (p == n.id) {
        throw FormatException("node '${n.id}': lists itself as a prereq");
      }
      if (!nodeIds.contains(p)) {
        throw FormatException("node '${n.id}': unknown prereq '$p'");
      }
    }
  }

  return Course(
    id: id,
    title: title,
    subtitle: _optString(json, 'subtitle') ?? '',
    subject: _optString(json, 'subject') ?? '',
    level: _optString(json, 'level') ?? '',
    description: _optString(json, 'description') ?? '',
    srsDefaults: _parseSrsDefaults(json['srsDefaults']),
    nodes: nodes,
  );
}

SrsDefaults _parseSrsDefaults(Object? raw) {
  if (raw == null) return const SrsDefaults();
  if (raw is! Map<String, dynamic>) {
    throw const FormatException("course: 'srsDefaults' must be an object");
  }
  const defaults = SrsDefaults();
  return SrsDefaults(
    algorithm: _optString(raw, 'algorithm') ?? defaults.algorithm,
    initialEase: _optDouble(raw, 'initialEase') ?? defaults.initialEase,
    firstIntervalDays:
        _optInt(raw, 'firstIntervalDays') ?? defaults.firstIntervalDays,
  );
}

KnowledgeNode _parseNode(Map<String, dynamic> json, int index) {
  // Prefer the node's own id in error messages; fall back to its index.
  final idForError = _optString(json, 'id') ?? '#$index';

  final id = _reqString(json, 'id', "node '$idForError'");
  final title = _reqString(json, 'title', "node '$id'");
  final intake = _reqString(json, 'intake', "node '$id'");

  final rawItems = json['items'];
  if (rawItems is! List) {
    throw FormatException("node '$id': 'items' must be a list");
  }
  if (rawItems.isEmpty) {
    throw FormatException("node '$id': 'items' must not be empty");
  }

  final items = <RetrievalItem>[];
  for (var i = 0; i < rawItems.length; i++) {
    final raw = rawItems[i];
    if (raw is! Map<String, dynamic>) {
      throw FormatException("node '$id': items[$i] must be an object");
    }
    items.add(_parseItem(raw, id, i));
  }

  return KnowledgeNode(
    id: id,
    title: title,
    summary: _optString(json, 'summary') ?? '',
    prereqs: _optStringList(json, 'prereqs', "node '$id'") ?? const [],
    diagramMermaid: _optString(json, 'diagramMermaid'),
    intake: intake,
    items: items,
  );
}

RetrievalItem _parseItem(
  Map<String, dynamic> json,
  String nodeId,
  int index,
) {
  final id = _reqString(json, 'id', "node '$nodeId' item #$index");
  final itemWhere = "node '$nodeId' item '$id'";

  final rung = _reqInt(json, 'rung', itemWhere);

  final hints = _optStringList(json, 'hints', itemWhere) ?? const [];
  final sources = _optStringList(json, 'sources', itemWhere) ?? const [];

  final typeRaw = json['type'];
  if (typeRaw == null) {
    throw FormatException("$itemWhere: missing required 'type'");
  }
  if (typeRaw is! String) {
    throw FormatException("$itemWhere: 'type' must be a string");
  }

  switch (typeRaw) {
    case 'cloze':
      final text = _optString(json, 'text');
      final answers = _parseAnswers(json['answers'], itemWhere);
      if (text == null || answers == null) {
        throw FormatException(
          "$itemWhere: cloze requires 'text' and 'answers'",
        );
      }
      if (answers.isEmpty) {
        throw FormatException("$itemWhere: cloze 'answers' must not be empty");
      }
      return ClozeItem(
        id: id,
        rung: rung,
        hints: hints,
        sources: sources,
        text: text,
        answers: answers,
      );

    case 'qa':
      final prompt = _optString(json, 'prompt');
      final answer = _optString(json, 'answer');
      if (prompt == null || answer == null) {
        throw FormatException(
          "$itemWhere: qa requires 'prompt' and 'answer'",
        );
      }
      return QaItem(
        id: id,
        rung: rung,
        hints: hints,
        sources: sources,
        prompt: prompt,
        answer: answer,
        acceptable:
            _optStringList(json, 'acceptable', itemWhere) ?? const [],
        rubric: _optString(json, 'rubric'),
      );

    case 'discrimination':
      final prompt = _optString(json, 'prompt');
      final choices = _optStringList(json, 'choices', itemWhere);
      final correctIndex = _optInt(json, 'correctIndex');
      if (prompt == null || choices == null || correctIndex == null) {
        throw FormatException(
          "$itemWhere: discrimination requires 'prompt', 'choices', "
          "and 'correctIndex'",
        );
      }
      if (choices.isEmpty) {
        throw FormatException(
          "$itemWhere: discrimination 'choices' must not be empty",
        );
      }
      if (correctIndex < 0 || correctIndex >= choices.length) {
        throw FormatException(
          "$itemWhere: discrimination 'correctIndex' ($correctIndex) is out "
          "of range for ${choices.length} choices",
        );
      }
      return DiscriminationItem(
        id: id,
        rung: rung,
        hints: hints,
        sources: sources,
        prompt: prompt,
        choices: choices,
        correctIndex: correctIndex,
        explanation: _optString(json, 'explanation'),
      );

    case 'procedure':
      final prompt = _optString(json, 'prompt');
      final steps = _optStringList(json, 'steps', itemWhere);
      if (prompt == null || steps == null) {
        throw FormatException(
          "$itemWhere: procedure requires 'prompt' and 'steps'",
        );
      }
      if (steps.isEmpty) {
        throw FormatException(
          "$itemWhere: procedure 'steps' must not be empty",
        );
      }
      return ProcedureItem(
        id: id,
        rung: rung,
        hints: hints,
        sources: sources,
        prompt: prompt,
        steps: steps,
        rubric: _optString(json, 'rubric'),
      );

    default:
      throw FormatException(
        "$itemWhere: unknown item type '$typeRaw' "
        "(expected one of: cloze, qa, discrimination, procedure)",
      );
  }
}

// --- field helpers -----------------------------------------------------------

/// Returns a required string field, throwing [FormatException] if missing or
/// not a string. [where] is a path prefix for the error message.
String _reqString(Map<String, dynamic> json, String key, String where) {
  final value = json[key];
  if (value == null) {
    throw FormatException("$where: missing required '$key'");
  }
  if (value is! String) {
    throw FormatException("$where: '$key' must be a string");
  }
  return value;
}

/// Returns an optional string field, or null if absent. Throws if present but
/// not a string.
String? _optString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) {
    throw FormatException("'$key' must be a string");
  }
  return value;
}

int _reqInt(Map<String, dynamic> json, String key, String where) {
  final value = json[key];
  if (value == null) {
    throw FormatException("$where: missing required '$key'");
  }
  if (value is! int) {
    throw FormatException("$where: '$key' must be an integer");
  }
  return value;
}

int? _optInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! int) {
    throw FormatException("'$key' must be an integer");
  }
  return value;
}

/// Accepts either an int or a double in JSON (JSON has one number type) and
/// returns it as a double; null if absent.
double? _optDouble(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is num) return value.toDouble();
  throw FormatException("'$key' must be a number");
}

/// Returns an optional list-of-strings field, or null if absent. Throws if
/// present but not a list of strings.
List<String>? _optStringList(
  Map<String, dynamic> json,
  String key,
  String where,
) {
  final value = json[key];
  if (value == null) return null;
  if (value is! List) {
    throw FormatException("$where: '$key' must be a list of strings");
  }
  final out = <String>[];
  for (final element in value) {
    if (element is! String) {
      throw FormatException("$where: '$key' must be a list of strings");
    }
    out.add(element);
  }
  return out;
}

/// Parses the cloze `answers` map (blank key -> expected answer). Returns null
/// if absent. Throws if present but not a string->string map.
Map<String, String>? _parseAnswers(Object? raw, String where) {
  if (raw == null) return null;
  if (raw is! Map) {
    throw FormatException("$where: 'answers' must be an object");
  }
  final out = <String, String>{};
  raw.forEach((key, value) {
    if (key is! String || value is! String) {
      throw FormatException(
        "$where: 'answers' must map string keys to string values",
      );
    }
    out[key] = value;
  });
  return out;
}
