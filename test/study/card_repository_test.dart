import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trellis/features/study/data/card_repository.dart';

void main() {
  test('load returns empty for corrupt (non-JSON) stored data, not a crash',
      () async {
    // load() runs unguarded in the study screen's initState — corrupt prefs
    // must degrade to "no saved cards", never throw.
    SharedPreferences.setMockInitialValues({'cards:x': 'not json at all'});
    final repo = CardRepository(await SharedPreferences.getInstance());
    expect(repo.load('x'), isEmpty);
  });

  test('load skips a malformed card entry but keeps the valid ones', () async {
    SharedPreferences.setMockInitialValues({
      'cards:x': jsonEncode({
        'good': {
          'ease': 2.5,
          'intervalDays': 1,
          'dueEpochDay': 100,
          'reps': 3,
          'lapses': 0,
        },
        'bad': {'ease': 'oops'}, // wrong types / missing fields
      }),
    });
    final repo = CardRepository(await SharedPreferences.getInstance());
    final cards = repo.load('x');
    expect(cards.keys, ['good']);
    expect(cards['good']!.ease, 2.5);
  });
}
