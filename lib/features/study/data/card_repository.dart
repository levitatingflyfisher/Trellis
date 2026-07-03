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
    try {
      final decoded = json.decode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      final result = <String, CardState>{};
      decoded.forEach((itemId, v) {
        if (v is! Map<String, dynamic>) return;
        final ease = v['ease'];
        final intervalDays = v['intervalDays'];
        final dueEpochDay = v['dueEpochDay'];
        final reps = v['reps'];
        final lapses = v['lapses'];
        // Skip a malformed entry rather than losing the whole course's progress.
        if (ease is! num ||
            intervalDays is! int ||
            dueEpochDay is! int ||
            reps is! int ||
            lapses is! int) {
          return;
        }
        result[itemId] = CardState(
          itemId: itemId,
          ease: ease.toDouble(),
          intervalDays: intervalDays,
          dueEpochDay: dueEpochDay,
          reps: reps,
          lapses: lapses,
        );
      });
      return result;
    } catch (_) {
      // Corrupt store must not crash study startup (load runs in initState);
      // start this course fresh.
      return {};
    }
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
