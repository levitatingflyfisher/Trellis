import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/models.dart';
import 'curriculum_parser.dart';

/// Loads courses from two places: `.ohcourse` files bundled in
/// `assets/courses/`, and user-imported courses persisted in
/// shared_preferences. Imported courses override bundled ones with the same id.
class CourseRepository {
  CourseRepository(this._prefs);
  final SharedPreferences _prefs;

  /// shared_preferences key for the index of imported course ids. Public so
  /// the encrypted-backup serializer (lib/features/sanctuary_backup) can dump
  /// and restore the exact same keys without duplicating the literal string
  /// (SANCTUARY-BRIEF §4.W2 — reduces churn if this key ever changes).
  static const indexKey = 'imported_ids';

  /// shared_preferences key holding a single imported course's raw
  /// `.ohcourse` JSON text.
  static String courseKey(String id) => 'course:$id';

  Future<List<Course>> listCourses() async {
    final byId = <String, Course>{};
    for (final c in await _bundledCourses()) {
      byId[c.id] = c;
    }
    for (final id in _importedIds()) {
      final raw = _prefs.getString(courseKey(id));
      if (raw == null) continue;
      try {
        byId[id] = parseCourseString(raw);
      } catch (_) {
        // skip a corrupt stored course rather than crash the library
      }
    }
    final list = byId.values.toList()
      ..sort((a, b) => a.title.compareTo(b.title));
    return list;
  }

  /// Validates and stores a pasted/loaded `.ohcourse` JSON. Throws
  /// [FormatException] (from the parser) if malformed.
  Future<Course> importFromJson(String jsonText) async {
    final course = parseCourseString(jsonText); // throws on malformed
    await _prefs.setString(courseKey(course.id), jsonText);
    final ids = _importedIds().toSet()..add(course.id);
    await _prefs.setStringList(indexKey, ids.toList());
    return course;
  }

  List<String> _importedIds() => _prefs.getStringList(indexKey) ?? const [];

  // Bundled courses are listed explicitly in assets/courses/index.json (a JSON
  // array of filenames). This is deterministic — unlike AssetManifest, which has
  // proven flaky (the deprecated AssetManifest.json, and stale test caches).
  // Bundled assets never change at runtime, so parse them at most once. Without
  // this, every coursesProvider invalidation (e.g. after importing one small
  // course) re-read + re-parsed + re-validated the whole bundled corpus.
  List<Course>? _bundledCache;

  Future<List<Course>> _bundledCourses() async {
    if (_bundledCache != null) return _bundledCache!;
    List<dynamic> names;
    try {
      names = json.decode(await rootBundle.loadString('assets/courses/index.json'))
          as List<dynamic>;
    } catch (_) {
      return const [];
    }
    final out = <Course>[];
    for (final n in names) {
      try {
        out.add(parseCourseString(
            await rootBundle.loadString('assets/courses/$n')));
      } catch (_) {
        // a malformed bundled file shouldn't take down the app
      }
    }
    return _bundledCache = out;
  }
}
