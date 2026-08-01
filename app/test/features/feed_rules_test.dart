import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/feeds/feed_rules.dart';

/// Phase 3 (Campaign 5): per-feed deterministic rules, evaluated at
/// refresh time, BEFORE an item ever enters the river. Rules run in
/// order; the first whose condition matches decides the item's fate.
/// No match at all means "enter the river as normal" — the default,
/// unaffected behavior for every feed that has never touched this
/// screen.
void main() {
  group('evaluateFeedRules', () {
    test('an empty rule list never matches — normal ingest', () {
      expect(
          evaluateFeedRules(const [],
              title: 'Anything', description: 'Anything'),
          isNull);
    });

    test('contains matches case-insensitively on the title', () {
      const rules = [
        FeedRule(
            field: FeedRuleField.title,
            match: FeedRuleMatch.contains,
            text: 'sponsored',
            action: FeedRuleAction.skip),
      ];
      expect(
          evaluateFeedRules(rules,
              title: 'This Episode Is SPONSORED', description: ''),
          FeedRuleAction.skip);
      expect(
          evaluateFeedRules(rules, title: 'A normal episode', description: ''),
          isNull);
    });

    test('notContains matches when the text is absent', () {
      const rules = [
        FeedRule(
            field: FeedRuleField.description,
            match: FeedRuleMatch.notContains,
            text: 'transcript',
            action: FeedRuleAction.markReadOnArrival),
      ];
      expect(
          evaluateFeedRules(rules,
              title: '', description: 'No written version here'),
          FeedRuleAction.markReadOnArrival);
      expect(
          evaluateFeedRules(rules,
              title: '', description: 'Full transcript below'),
          isNull);
    });

    test('matches on description, not title, when the field says so', () {
      const rules = [
        FeedRule(
            field: FeedRuleField.description,
            match: FeedRuleMatch.contains,
            text: 'interview',
            action: FeedRuleAction.autoKeep),
      ];
      expect(
          evaluateFeedRules(rules,
              title: 'An interview happened', description: 'A recap.'),
          isNull,
          reason: 'the word is in the title, the rule reads description');
      expect(
          evaluateFeedRules(rules,
              title: 'Episode 4', description: 'An interview with someone'),
          FeedRuleAction.autoKeep);
    });

    test('the FIRST matching rule wins, later rules never run', () {
      const rules = [
        FeedRule(
            field: FeedRuleField.title,
            match: FeedRuleMatch.contains,
            text: 'ad',
            action: FeedRuleAction.skip),
        FeedRule(
            field: FeedRuleField.title,
            match: FeedRuleMatch.contains,
            text: 'advert',
            action: FeedRuleAction.markReadOnArrival),
      ];
      // "advertisement" contains both "ad" and "advert" — the first rule
      // (skip) must win.
      expect(
          evaluateFeedRules(rules,
              title: 'Advertisement break', description: ''),
          FeedRuleAction.skip);
    });

    test('a rule that never matches leaves later rules a chance', () {
      const rules = [
        FeedRule(
            field: FeedRuleField.title,
            match: FeedRuleMatch.contains,
            text: 'nonsense-xyz',
            action: FeedRuleAction.skip),
        FeedRule(
            field: FeedRuleField.title,
            match: FeedRuleMatch.contains,
            text: 'episode',
            action: FeedRuleAction.autoKeep),
      ];
      expect(
          evaluateFeedRules(rules, title: 'Episode 12', description: ''),
          FeedRuleAction.autoKeep);
    });
  });

  group('JSON round-trip — the Feeds.rulesJson persistence codec', () {
    test('an ordered list survives encode/decode exactly', () {
      const rules = [
        FeedRule(
            field: FeedRuleField.title,
            match: FeedRuleMatch.contains,
            text: 'sponsored',
            action: FeedRuleAction.skip),
        FeedRule(
            field: FeedRuleField.description,
            match: FeedRuleMatch.notContains,
            text: 'transcript',
            action: FeedRuleAction.markReadOnArrival),
      ];
      final decoded = decodeFeedRules(encodeFeedRules(rules));
      expect(decoded.length, 2);
      expect(decoded[0].field, FeedRuleField.title);
      expect(decoded[0].match, FeedRuleMatch.contains);
      expect(decoded[0].text, 'sponsored');
      expect(decoded[0].action, FeedRuleAction.skip);
      expect(decoded[1].field, FeedRuleField.description);
      expect(decoded[1].match, FeedRuleMatch.notContains);
      expect(decoded[1].action, FeedRuleAction.markReadOnArrival);
    });

    test('the default column value decodes to an empty list', () {
      expect(decodeFeedRules('[]'), isEmpty);
    });

    test('garbage decodes to an empty list rather than throwing', () {
      expect(decodeFeedRules('not json'), isEmpty);
    });
  });
}
