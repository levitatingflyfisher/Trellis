// Round-trip + envelope tests for the encrypted-backup (.ohbk) serializer.
//
// TrellisBackupSerializer works directly on the app's SharedPreferences
// instance (mirroring Lullaby's AppDatabase-direct serializer — no filtered
// repository layer in between) and wraps a faithful raw-string dump of the
// existing keys in an `{app, schemaVersion, payload}` envelope
// (SANCTUARY-BRIEF §2.8, §4.W2). These tests pin:
//
//   1. dumpAll produces a valid envelope carrying the app id + schema version.
//   2. Backup scope: IMPORTED courses (content + index) are backed up;
//      per-course SM-2 progress is backed up for ANY course — bundled or
//      imported — because bundled course *content* ships with the app but
//      study progress against it does not.
//   3. restoreAll round-trips courses/cards/index through the same store.
//   4. restoreAll is destructive: keys not in the backup are gone afterward.
//   5. restoreAll rejects a wrong app id and a future schema version.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary_backup_ui/sanctuary_backup_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trellis/features/curriculum/data/course_repository.dart';
import 'package:trellis/features/sanctuary_backup/data/backup_serializer.dart';
import 'package:trellis/features/study/data/card_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late TrellisBackupSerializer serializer;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    serializer = TrellisBackupSerializer(prefs);
  });

  const kalmanCourseJson =
      '{"schemaVersion":"1.0","id":"kalman-filters","title":"Kalman Filters"}';
  const otherCourseJson =
      '{"schemaVersion":"1.0","id":"other-course","title":"Other Course"}';
  const kalmanCards = '{"ss-1":{"ease":2.5,"intervalDays":1,'
      '"dueEpochDay":19000,"reps":1,"lapses":0}}';
  const bundledCards = '{"b-1":{"ease":2.3,"intervalDays":3,'
      '"dueEpochDay":19010,"reps":2,"lapses":1}}';

  Future<void> seedImportedCourse(String id, String json) async {
    await prefs.setString(CourseRepository.courseKey(id), json);
    final ids = (prefs.getStringList(CourseRepository.indexKey) ?? [])
      ..add(id);
    await prefs.setStringList(CourseRepository.indexKey, ids);
  }

  Future<void> seedCards(String courseId, String json) =>
      prefs.setString(CardRepository.key(courseId), json);

  group('dumpAll', () {
    test('envelope carries app id and schema version', () async {
      final bytes = await serializer.dumpAll();
      final envelope = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

      expect(envelope['app'], 'trellis');
      expect(envelope['schemaVersion'], isA<int>());
      expect(envelope['payload'], isA<Map<String, dynamic>>());
    });

    test('on an empty store, payload has empty collections', () async {
      final bytes = await serializer.dumpAll();
      final envelope = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final payload = envelope['payload'] as Map<String, dynamic>;

      expect(payload['importedIds'], isEmpty);
      expect(payload['courses'], isEmpty);
      expect(payload['cards'], isEmpty);
    });

    test('payload includes imported course text keyed by id', () async {
      await seedImportedCourse('kalman-filters', kalmanCourseJson);

      final bytes = await serializer.dumpAll();
      final envelope = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final payload = envelope['payload'] as Map<String, dynamic>;

      expect(payload['importedIds'], ['kalman-filters']);
      expect(
        (payload['courses'] as Map)['kalman-filters'],
        kalmanCourseJson,
      );
    });

    test(
        'payload includes progress for a BUNDLED course id even though its '
        'content is never dumped', () async {
      // "tracking-course" is never imported (no course:tracking-course key,
      // not in imported_ids) — it only has a cards: key, exactly like a
      // bundled asset course the user has studied.
      await seedCards('tracking-course', bundledCards);

      final bytes = await serializer.dumpAll();
      final envelope = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final payload = envelope['payload'] as Map<String, dynamic>;

      expect(payload['importedIds'], isEmpty);
      expect(payload['courses'], isEmpty);
      expect((payload['cards'] as Map)['tracking-course'], bundledCards);
    });
  });

  group('restoreAll — round-trip', () {
    test('restores imported courses, index, and cards into the same store',
        () async {
      await seedImportedCourse('kalman-filters', kalmanCourseJson);
      await seedCards('kalman-filters', kalmanCards);
      await seedCards('tracking-course', bundledCards); // bundled, unindexed

      final bytes = await serializer.dumpAll();
      await serializer.restoreAll(bytes);

      expect(
        prefs.getStringList(CourseRepository.indexKey),
        ['kalman-filters'],
      );
      expect(
        prefs.getString(CourseRepository.courseKey('kalman-filters')),
        kalmanCourseJson,
      );
      expect(
        prefs.getString(CardRepository.key('kalman-filters')),
        kalmanCards,
      );
      expect(
        prefs.getString(CardRepository.key('tracking-course')),
        bundledCards,
      );
    });

    test('restoreAll is destructive: keys absent from the backup are gone',
        () async {
      await seedImportedCourse('kalman-filters', kalmanCourseJson);
      final bytes = await serializer.dumpAll();

      // Data added AFTER the dump must not survive restore.
      await seedImportedCourse('other-course', otherCourseJson);
      await seedCards('other-course', kalmanCards);

      await serializer.restoreAll(bytes);

      expect(
        prefs.getStringList(CourseRepository.indexKey),
        ['kalman-filters'],
      );
      expect(prefs.getString(CourseRepository.courseKey('other-course')),
          isNull);
      expect(prefs.getString(CardRepository.key('other-course')), isNull);
    });

    test('restoreAll never touches unrelated shared_preferences keys',
        () async {
      await prefs.setString('some_unrelated_pref', 'keep-me');
      await seedImportedCourse('kalman-filters', kalmanCourseJson);
      final bytes = await serializer.dumpAll();

      await serializer.restoreAll(bytes);

      expect(prefs.getString('some_unrelated_pref'), 'keep-me');
    });
  });

  group('restoreAll — rejection', () {
    test('rejects a backup made for a different app', () async {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode({
        'app': 'lullaby',
        'schemaVersion': 1,
        'payload': {'importedIds': [], 'courses': {}, 'cards': {}},
      })));

      expect(
        () => serializer.restoreAll(bytes),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a missing app field', () async {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode({
        'schemaVersion': 1,
        'payload': {'importedIds': [], 'courses': {}, 'cards': {}},
      })));

      expect(
        () => serializer.restoreAll(bytes),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a future schema version', () async {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode({
        'app': 'trellis',
        'schemaVersion': 999,
        'payload': {'importedIds': [], 'courses': {}, 'cards': {}},
      })));

      expect(
        () => serializer.restoreAll(bytes),
        throwsA(isA<BackupSchemaException>()),
      );
    });

    test('rejects a missing schemaVersion', () async {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode({
        'app': 'trellis',
        'payload': {'importedIds': [], 'courses': {}, 'cards': {}},
      })));

      expect(
        () => serializer.restoreAll(bytes),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a missing payload', () async {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode({
        'app': 'trellis',
        'schemaVersion': 1,
      })));

      expect(
        () => serializer.restoreAll(bytes),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects data that is not valid JSON', () async {
      final bytes = Uint8List.fromList(utf8.encode('not json'));

      expect(
        () => serializer.restoreAll(bytes),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
