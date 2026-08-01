/// Per-feed deterministic rules (Campaign 5 Phase 3), evaluated at
/// ingest — BEFORE an item ever becomes a river row. Pure: no DB, no
/// network, so the rule matrix is testable without a database.
library;

import 'dart:convert';

enum FeedRuleField { title, description }

enum FeedRuleMatch { contains, notContains }

/// - skip: the item never enters the river at all — no row, nothing to
///   hide, nothing to undo (unlike the river's Keep/Let-it-pass, which
///   act on an item already there).
/// - markReadOnArrival: enters normally, then is marked read immediately
///   — visible, but never shows an unread dot.
/// - autoKeep: enters normally, then is promoted straight to the
///   library and marked read — the same transition Keep performs by
///   hand, just automatic.
enum FeedRuleAction { skip, markReadOnArrival, autoKeep }

/// One condition-action pair. Text matching is case-insensitive.
class FeedRule {
  final FeedRuleField field;
  final FeedRuleMatch match;
  final String text;
  final FeedRuleAction action;

  const FeedRule(
      {required this.field,
      required this.match,
      required this.text,
      required this.action});

  Map<String, Object?> toJson() => {
        'field': field.name,
        'match': match.name,
        'text': text,
        'action': action.name,
      };

  factory FeedRule.fromJson(Map<String, Object?> json) => FeedRule(
        field: FeedRuleField.values.byName(json['field'] as String),
        match: FeedRuleMatch.values.byName(json['match'] as String),
        text: json['text'] as String,
        action: FeedRuleAction.values.byName(json['action'] as String),
      );
}

/// Evaluates [rules] in order against one item's title/description;
/// returns the FIRST matching rule's action, or null when nothing
/// matches — the unaffected default for every feed with no rules (or
/// none that fire).
FeedRuleAction? evaluateFeedRules(List<FeedRule> rules,
    {required String title, required String description}) {
  for (final rule in rules) {
    final haystack =
        (rule.field == FeedRuleField.title ? title : description)
            .toLowerCase();
    final needle = rule.text.toLowerCase();
    final present = haystack.contains(needle);
    final fires =
        rule.match == FeedRuleMatch.contains ? present : !present;
    if (fires) return rule.action;
  }
  return null;
}

/// [Feeds.rulesJson]'s persistence codec — the house pattern (see
/// `encodeBreakerState`/`decodeBreakerState` in feed_ingest.dart).
String encodeFeedRules(List<FeedRule> rules) =>
    jsonEncode([for (final r in rules) r.toJson()]);

/// Garbage (including the pre-Phase-3 default `'[]'`, and anything that
/// fails to parse) decodes to an empty list rather than throwing — a
/// corrupt or absent rule set behaves exactly like "no rules", never
/// breaks a refresh.
List<FeedRule> decodeFeedRules(String json) {
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return const [];
    return [
      for (final entry in decoded)
        FeedRule.fromJson((entry as Map).cast<String, Object?>())
    ];
  } catch (_) {
    return const [];
  }
}
