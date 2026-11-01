/// Making and editing a card by hand (owner, 28 Oct: "have we fixed the
/// flashcard mechanics for highlighting and writing stuff and editing it
/// reasonable?", and "I don't see anything stolen from mochi or from anki
/// on having cloze").
///
/// A card is an item in its course's own text (`.ohcourse`), so every
/// change here returns a new course text, and every new text must pass
/// study_core's strict parser before it is returned. Nothing here touches
/// scheduling: a card keeps its id when edited, so its history stays with
/// it, as in Anki. Two kinds are made by hand: front and back (a `qa`
/// item) and cloze, written the Anki way as `{{c1::answer}}`. The other
/// two kinds (choice and steps) come only from course files.
///
/// Pure Dart, no Flutter: the editor and the database are elsewhere.
library;

import 'dart:convert';

import 'package:study_core/study_core.dart' as study;

/// The course a card made from no course goes into (from the reader, or
/// from the Courses tab). It is made with its first card.
const myCardsCourseId = 'my-cards';
const myCardsTitle = 'My cards';

enum CardKind { frontBack, cloze }

/// What the editor holds: a front and back, or a cloze text in [front].
class CardDraft {
  final CardKind kind;
  final String front;
  final String back;

  const CardDraft.frontBack(this.front, this.back) : kind = CardKind.frontBack;
  const CardDraft.cloze(this.front)
      : kind = CardKind.cloze,
        back = '';

  @override
  bool operator ==(Object other) =>
      other is CardDraft &&
      other.kind == kind &&
      other.front == front &&
      other.back == back;

  @override
  int get hashCode => Object.hash(kind, front, back);

  @override
  String toString() => 'CardDraft($kind, $front, $back)';
}

/// The same pattern the study session blanks by, so what is written here
/// is exactly what is asked there.
final _cloze = RegExp(r'\{\{(c\d+)::([^}]*)\}\}');

/// The blanks in [text], each number to its answer. Anki's
/// `{{c1::answer::hint}}` is read too: the hint is not the answer.
/// Throws [FormatException] with a plain sentence when there is no blank,
/// a blank is empty, or one number has two answers.
Map<String, String> clozeAnswersOf(String text) {
  final out = <String, String>{};
  for (final m in _cloze.allMatches(text)) {
    final answer = m.group(2)!.split('::').first.trim();
    if (answer.isEmpty) {
      throw const FormatException('A blank is empty. Put the hidden words '
          'between the colons and the braces.');
    }
    final key = m.group(1)!;
    final before = out[key];
    if (before != null && before != answer) {
      throw FormatException('$key hides two different answers. Give the '
          'second one a new number, like c2.');
    }
    out[key] = answer;
  }
  if (out.isEmpty) {
    throw const FormatException(
        'A cloze card needs at least one blank, written {{c1::like this}}.');
  }
  return out;
}

/// [text] with its characters from [start] to [end] made a blank, under
/// the next number not yet used. Nothing selected changes nothing.
String blankSelection(String text, int start, int end) {
  if (start < 0 || end > text.length || end <= start) return text;
  final used = {
    for (final m in _cloze.allMatches(text)) int.parse(m.group(1)!.substring(1))
  };
  var n = 1;
  while (used.contains(n)) {
    n++;
  }
  return '${text.substring(0, start)}{{c$n::${text.substring(start, end)}}}'
      '${text.substring(end)}';
}

/// [sentence] with [word] made its first blank: a word held in the reader
/// becomes a card that asks for it in its own sentence. The whole word is
/// preferred over the start of a longer one; where words are not set
/// apart by spaces (Japanese, Chinese) the first place it appears is used.
/// A sentence without the word is returned as it is.
String clozeFromSentence(String sentence, String word) {
  if (word.isEmpty) return sentence;
  final whole = RegExp(
      '(?<![\\p{L}\\p{N}])${RegExp.escape(word)}(?![\\p{L}\\p{N}])',
      unicode: true);
  final at = whole.firstMatch(sentence)?.start ?? sentence.indexOf(word);
  if (at < 0) return sentence;
  return blankSelection(sentence, at, at + word.length);
}

/// The draft an existing item reads back as; null for the kinds that are
/// not made by hand.
CardDraft? draftOf(study.RetrievalItem item) => switch (item) {
      study.QaItem(:final prompt, :final answer) =>
        CardDraft.frontBack(prompt, answer),
      study.ClozeItem(:final text) => CardDraft.cloze(text),
      _ => null,
    };

/// A new id for a card, unlike any in [taken].
String newCardId(Set<String> taken, int nowMs) {
  final base = 'card-$nowMs';
  if (!taken.contains(base)) return base;
  var n = 2;
  while (taken.contains('$base-$n')) {
    n++;
  }
  return '$base-$n';
}

/// The item JSON for [draft], over [old] when editing: what the parser
/// ignores and the hints and sources stay; the old kind's own fields go,
/// and so do a front and back card's keyword anchors, which were written
/// for the old answer.
Map<String, dynamic> _itemJson(CardDraft draft, String id,
    [Map<String, dynamic>? old]) {
  final out = <String, dynamic>{...?old};
  for (final k in const [
    'type', 'rung', 'text', 'answers', 'prompt', 'answer', 'acceptable',
    'rubric', 'choices', 'correctIndex', 'explanation', 'steps',
  ]) {
    out.remove(k);
  }
  out['id'] = id;
  switch (draft.kind) {
    case CardKind.frontBack:
      final front = draft.front.trim(), back = draft.back.trim();
      if (front.isEmpty) {
        throw const FormatException('The front is empty.');
      }
      if (back.isEmpty) throw const FormatException('The back is empty.');
      out
        ..['type'] = 'qa'
        // A typed recall from a cue, as most hand-made cards are.
        ..['rung'] = 3
        ..['prompt'] = front
        ..['answer'] = back;
    case CardKind.cloze:
      final text = draft.front.trim();
      out
        ..['type'] = 'cloze'
        ..['rung'] = 1
        ..['text'] = text
        ..['answers'] = clozeAnswersOf(text);
  }
  return out;
}

Map<String, dynamic> _decode(String raw) {
  study.parseCourseString(raw); // refuses a text that is not a course
  return json.decode(raw) as Map<String, dynamic>;
}

/// Encodes [course] and proves it parses before anyone stores it.
String _encode(Map<String, dynamic> course) {
  final raw = const JsonEncoder.withIndent('  ').convert(course);
  study.parseCourseString(raw);
  return raw;
}

Iterable<Map<String, dynamic>> _nodes(Map<String, dynamic> course) =>
    (course['nodes'] as List).cast<Map<String, dynamic>>();

/// [raw] with a card made from [draft] added at the end of step [nodeId].
String courseWithNewCard(String raw,
    {required String nodeId,
    required String itemId,
    required CardDraft draft}) {
  final course = _decode(raw);
  final node = _nodes(course).firstWhere((n) => n['id'] == nodeId,
      orElse: () => throw StateError('no step $nodeId'));
  (node['items'] as List).add(_itemJson(draft, itemId));
  return _encode(course);
}

/// [raw] with item [itemId] made from [draft], keeping its id.
String courseWithEditedCard(String raw, String itemId, CardDraft draft) {
  final course = _decode(raw);
  for (final node in _nodes(course)) {
    final items = node['items'] as List;
    for (var i = 0; i < items.length; i++) {
      final item = items[i] as Map<String, dynamic>;
      if (item['id'] == itemId) {
        items[i] = _itemJson(draft, itemId, item);
        return _encode(course);
      }
    }
  }
  throw StateError('no card $itemId');
}

/// [raw] without item [itemId]. A step's last card is never taken out (a
/// step with no cards is not a course the parser accepts); that throws
/// [StateError].
String courseWithoutCard(String raw, String itemId) {
  final course = _decode(raw);
  for (final node in _nodes(course)) {
    final items = node['items'] as List;
    final at = items.indexWhere((i) => (i as Map)['id'] == itemId);
    if (at < 0) continue;
    if (items.length == 1) {
      throw StateError('the last card of a step stays');
    }
    items.removeAt(at);
    return _encode(course);
  }
  throw StateError('no card $itemId');
}

/// The My cards course, made with its first card. Its one step has no
/// reading: a session goes straight to the cards.
String newMyCardsCourse({required String itemId, required CardDraft draft}) =>
    _encode({
      'schemaVersion': study.kSupportedSchemaVersion,
      'id': myCardsCourseId,
      'title': myCardsTitle,
      'subtitle': 'Cards you made yourself',
      'nodes': [
        {
          'id': myCardsCourseId,
          'title': myCardsTitle,
          'intake': '',
          'items': [_itemJson(draft, itemId)],
        },
      ],
    });
