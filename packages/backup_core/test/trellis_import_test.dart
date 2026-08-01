import 'dart:convert';
import 'dart:typed_data';

import 'package:backup_core/backup_core.dart';
import 'package:sanctuary_auth_core/sanctuary_auth_core.dart';
import 'package:test/test.dart';

const phrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon about';
const otherPhrase =
    'legal winner thank year wave sausage worth useful legal winner '
    'thank yellow';

/// Builds a `.ohbk` blob exactly as the donor Trellis app writes one:
/// fleet `BackupEnvelope` JSON (`{app, schemaVersion, createdAt, payload}`)
/// encrypted with the donor's derivation (appDomain `trellis`, AAD
/// `trellis-backup/v1`) — real sanctuary crypto, no mocks.
Future<Uint8List> donorBlob(
  Map<String, Object?> payload, {
  String app = 'trellis',
  int schemaVersion = 1,
  String withPhrase = phrase,
}) async {
  final envelope = <String, Object?>{
    'app': app,
    'schemaVersion': schemaVersion,
    'createdAt': '2026-08-01T00:00:00.000Z',
    'payload': payload,
  };
  final seed = await OpenHearthMnemonic.deriveSeed(withPhrase);
  final keys = await KeyDerivation.fromSeed(seed, appDomain: trellisAppDomain);
  return GhostBackup.export(
    Uint8List.fromList(utf8.encode(jsonEncode(envelope))),
    keys.masterEncryptionKey,
    EnvelopeCipher(),
    context: trellisAadContext,
  );
}

/// The donor's per-course card blob: `{itemId: {ease, intervalDays,
/// dueEpochDay, reps, lapses}}` as a raw JSON string (CardRepository.save).
String donorCards(Map<String, Map<String, Object?>> byItem) =>
    jsonEncode(byItem);

void main() {
  group('TrellisImporter', () {
    test('decrypts a donor blob and maps courses + cards into row maps',
        () async {
      final blob = await donorBlob({
        'importedIds': ['course-a', 'course-b'],
        'courses': {
          'course-a': '{"id":"course-a","title":"Alpha"}',
          'course-b': '{"id":"course-b","title":"Beta"}',
        },
        'cards': {
          'course-a': donorCards({
            'item-1': {
              'ease': 2.5,
              'intervalDays': 6,
              'dueEpochDay': 20670,
              'reps': 2,
              'lapses': 1,
            },
          }),
        },
      });

      final result = await TrellisImporter.importBackup(
        blob,
        phrase: phrase,
        profileId: 'p1',
      );

      // Courses arrive in importedIds order, bodies verbatim (the donor's
      // restore precedent: raw strings, never re-serialized).
      expect(result.tables['courses'], [
        {'id': 'course-a', 'body': '{"id":"course-a","title":"Alpha"}'},
        {'id': 'course-b', 'body': '{"id":"course-b","title":"Beta"}'},
      ]);
      expect(result.tables['cards'], [
        {
          'profileId': 'p1',
          'courseId': 'course-a',
          'itemId': 'item-1',
          'ease': 2.5,
          'intervalDays': 6,
          'dueEpochDay': 20670,
          'reps': 2,
          'lapses': 1,
        },
      ]);
      expect(result.report.imported, {'courses': 2, 'cards': 1});
      expect(result.report.skipped, isEmpty);
    });

    test(
        'SM-2 state maps 1:1 — every donor field lands under the same name; '
        'the ONLY loss is that the donor kept no review log, so revlog is '
        'empty and the report says so', () async {
      final blob = await donorBlob({
        'importedIds': ['c'],
        'courses': {'c': '{"id":"c"}'},
        'cards': {
          'c': donorCards({
            'item-x': {
              'ease': 1.3,
              'intervalDays': 1,
              'dueEpochDay': 20500,
              'reps': 0,
              'lapses': 7,
            },
          }),
        },
      });

      final result = await TrellisImporter.importBackup(
        blob,
        phrase: phrase,
        profileId: 'p1',
      );

      final card = result.tables['cards']!.single;
      // 1:1, field for field — nothing renamed, nothing rescaled.
      expect(card['ease'], 1.3);
      expect(card['intervalDays'], 1);
      expect(card['dueEpochDay'], 20500);
      expect(card['reps'], 0);
      expect(card['lapses'], 7);
      // The named loss: no per-review history ever existed in the donor.
      expect(result.tables['revlog'], isEmpty);
      expect(
        result.report.dropped.join(' '),
        contains('review log'),
      );
    });

    test('progress for a bundled course (cards without a course body) is '
        'imported — the progress is the user\'s', () async {
      final blob = await donorBlob({
        'importedIds': <String>[],
        'courses': <String, Object?>{},
        'cards': {
          'bundled-101': donorCards({
            'item-1': {
              'ease': 2.6,
              'intervalDays': 12,
              'dueEpochDay': 20700,
              'reps': 3,
              'lapses': 0,
            },
          }),
        },
      });

      final result = await TrellisImporter.importBackup(
        blob,
        phrase: phrase,
        profileId: 'p1',
      );

      expect(result.tables['courses'], isEmpty);
      expect(result.tables['cards']!.single['courseId'], 'bundled-101');
    });

    test('a malformed card entry is skipped, the rest of the course '
        'survives (donor precedent: skip the entry, not the course)',
        () async {
      final blob = await donorBlob({
        'importedIds': ['c'],
        'courses': {'c': '{"id":"c"}'},
        'cards': {
          'c': donorCards({
            'good': {
              'ease': 2.5,
              'intervalDays': 6,
              'dueEpochDay': 20670,
              'reps': 2,
              'lapses': 0,
            },
            'bad': {
              'ease': 'NaN-ish',
              'intervalDays': 6,
              'dueEpochDay': 20670,
              'reps': 2,
              'lapses': 0,
            },
          }),
        },
      });

      final result = await TrellisImporter.importBackup(
        blob,
        phrase: phrase,
        profileId: 'p1',
      );

      expect(result.tables['cards']!.single['itemId'], 'good');
      expect(result.report.skipped.values.fold<int>(0, (a, b) => a + b), 1);
    });

    test('a cards blob that is not JSON-map-shaped is skipped whole '
        '(donor precedent: corrupt store starts that course fresh)',
        () async {
      final blob = await donorBlob({
        'importedIds': ['c'],
        'courses': {'c': '{"id":"c"}'},
        'cards': {'c': '[1,2,3]'},
      });

      final result = await TrellisImporter.importBackup(
        blob,
        phrase: phrase,
        profileId: 'p1',
      );

      expect(result.tables['cards'], isEmpty);
      expect(result.report.skipped.values.fold<int>(0, (a, b) => a + b), 1);
    });

    test('an importedIds entry with no course body cannot produce a course '
        'row — counted as skipped, named calmly', () async {
      final blob = await donorBlob({
        'importedIds': ['ghost-course'],
        'courses': <String, Object?>{},
        'cards': <String, Object?>{},
      });

      final result = await TrellisImporter.importBackup(
        blob,
        phrase: phrase,
        profileId: 'p1',
      );

      expect(result.tables['courses'], isEmpty);
      expect(result.report.skipped.keys.join(' '), contains('course'));
      expect(result.report.skipped.values.fold<int>(0, (a, b) => a + b), 1);
    });

    test('a course body missing from the imported index stays behind '
        '(the donor would restore it unlisted — invisible)', () async {
      final blob = await donorBlob({
        'importedIds': <String>[],
        'courses': {'orphan': '{"id":"orphan"}'},
        'cards': <String, Object?>{},
      });

      final result = await TrellisImporter.importBackup(
        blob,
        phrase: phrase,
        profileId: 'p1',
      );

      expect(result.tables['courses'], isEmpty);
      expect(result.report.skipped.values.fold<int>(0, (a, b) => a + b), 1);
    });

    test('wrong phrase fails closed', () async {
      final blob = await donorBlob({
        'importedIds': <String>[],
        'courses': <String, Object?>{},
        'cards': <String, Object?>{},
      });
      expect(
        () => TrellisImporter.importBackup(blob,
            phrase: otherPhrase, profileId: 'p1'),
        throwsA(isA<CryptoException>()),
      );
    });

    test('an envelope stamped for another app is rejected', () async {
      final blob = await donorBlob(
        {
          'importedIds': <String>[],
          'courses': <String, Object?>{},
          'cards': <String, Object?>{},
        },
        app: 'lullaby',
      );
      expect(
        () => TrellisImporter.importBackup(blob,
            phrase: phrase, profileId: 'p1'),
        throwsFormatException,
      );
    });

    test('a future donor schemaVersion is rejected', () async {
      final blob = await donorBlob(
        {
          'importedIds': <String>[],
          'courses': <String, Object?>{},
          'cards': <String, Object?>{},
        },
        schemaVersion: 2,
      );
      expect(
        () => TrellisImporter.importBackup(blob,
            phrase: phrase, profileId: 'p1'),
        throwsFormatException,
      );
    });

    test('result tables carry the full canonical shape and no consents key',
        () async {
      final blob = await donorBlob({
        'importedIds': <String>[],
        'courses': <String, Object?>{},
        'cards': <String, Object?>{},
      });

      final result = await TrellisImporter.importBackup(
        blob,
        phrase: phrase,
        profileId: 'p1',
      );

      expect(result.tables.keys.toSet(), espalierBackupTables.toSet());
      expect(result.tables.containsKey('consents'), isFalse);
      // The mapped tables re-encode cleanly under our own envelope law.
      expect(
        () => RowPayload.encode(result.tables,
            createdAt: DateTime.utc(2026, 8, 6)),
        returnsNormally,
      );
    });
  });
}
