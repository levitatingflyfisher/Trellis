import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../curriculum/domain/models.dart';

/// Persists per-item SM-2 [CardState] in shared_preferences, keyed by course.
/// (Swappable for Drift later — this is the MVP store behind a plain class.)
class CardRepository {
  CardRepository(this._prefs);
  final SharedPreferences _prefs;

  String _key(String courseId) => 'cards:$courseId';

  Map<String, CardState> load(String courseId) {
    final raw = _prefs.getString(_key(courseId));
    if (raw == null) return {};
    final map = json.decode(raw) as Map<String, dynamic>;
    return map.map((itemId, v) {
      final m = v as Map<String, dynamic>;
      return MapEntry(
        itemId,
        CardState(
          itemId: itemId,
          ease: (m['ease'] as num).toDouble(),
          intervalDays: m['intervalDays'] as int,
          dueEpochDay: m['dueEpochDay'] as int,
          reps: m['reps'] as int,
          lapses: m['lapses'] as int,
        ),
      );
    });
  }

  Future<void> save(String courseId, Map<String, CardState> cards) {
    final map = cards.map((itemId, c) => MapEntry(itemId, {
          'ease': c.ease,
          'intervalDays': c.intervalDays,
          'dueEpochDay': c.dueEpochDay,
          'reps': c.reps,
          'lapses': c.lapses,
        }));
    return _prefs.setString(_key(courseId), json.encode(map));
  }

  Future<void> upsert(String courseId, CardState card) async {
    final cards = load(courseId);
    cards[card.itemId] = card;
    await save(courseId, cards);
  }
}
