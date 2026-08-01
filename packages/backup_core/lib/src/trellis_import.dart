import 'dart:convert';
import 'dart:typed_data';

import 'package:sanctuary_auth_core/sanctuary_auth_core.dart';

import 'migration_report.dart';
import 'row_payload.dart';

/// The donor Trellis app's HKDF appDomain (frozen — shipped user backups).
const String trellisAppDomain = 'trellis';

/// The donor Trellis app's AAD context label (frozen — shipped user backups).
const String trellisAadContext = 'trellis-backup/v1';

/// The result of a Trellis donor import: row maps + the calm diff report.
class TrellisImportResult {
  final RowTables tables;
  final MigrationReport report;

  const TrellisImportResult({required this.tables, required this.report});
}

/// Imports a `.ohbk` file written by the donor Trellis app.
///
/// Donor payload shape (TrellisBackupSerializer, schema v1):
/// `{importedIds: [id], courses: {id: rawCourseJson}, cards:
/// {courseId: rawCardsJson}}` where rawCardsJson is `{itemId: {ease,
/// intervalDays, dueEpochDay, reps, lapses}}`.
///
/// Mapping notes (each pinned by a test):
///  - SM-2 state maps **1:1** — same field names, same units, no rescaling.
///  - Course bodies stay the donor's verbatim raw JSON strings.
///  - Cards for bundled courses (progress without a course body in the
///    backup) are imported — the progress is the user's.
///  - The only loss: the donor kept no review log, so `revlog` starts empty.
abstract final class TrellisImporter {
  static const int _donorSchemaVersion = 1;

  /// Decrypts [blob] with the donor's own derivation (appDomain
  /// [trellisAppDomain], AAD [trellisAadContext]) under [phrase], then maps
  /// the donor payload into our row maps.
  ///
  /// Cards are stamped with [profileId] — in this app SM-2 progress is
  /// profile-scoped; the donor was single-user.
  ///
  /// Fails closed: a wrong phrase or tampered blob throws `CryptoException`;
  /// a malformed envelope, another app's stamp, or a future donor schema
  /// throws [FormatException].
  static Future<TrellisImportResult> importBackup(
    Uint8List blob, {
    required String phrase,
    required String profileId,
  }) async {
    final seed = await OpenHearthMnemonic.deriveSeed(phrase);
    final keys =
        await KeyDerivation.fromSeed(seed, appDomain: trellisAppDomain);
    final plaintext = await GhostBackup.import(
      blob,
      keys.masterEncryptionKey,
      EnvelopeCipher(),
      context: trellisAadContext,
    );

    final payload = _unwrapDonorEnvelope(plaintext);
    final importedIds = _stringList(payload['importedIds']);
    final courses = _stringMap(payload['courses']);
    final cards = _stringMap(payload['cards']);

    final skipped = <String, int>{};
    void skip(String reason) =>
        skipped[reason] = (skipped[reason] ?? 0) + 1;

    // Courses: importedIds order, bodies verbatim (donor restore precedent —
    // raw strings, never re-serialized).
    final courseRows = <Map<String, Object?>>[];
    for (final id in importedIds) {
      final body = courses[id];
      if (body == null) {
        skip('course listed in the backup index without its content');
        continue;
      }
      courseRows.add({'id': id, 'body': body});
    }
    // A body absent from the index would be invisible in the donor too.
    for (final id in courses.keys) {
      if (!importedIds.contains(id)) {
        skip('course content not listed in the backup index');
      }
    }

    // Cards: parse each course's raw blob; skip malformed entries, not the
    // course (CardRepository.load precedent); skip a non-map blob whole.
    final cardRows = <Map<String, Object?>>[];
    for (final entry in cards.entries) {
      final Object? decoded;
      try {
        decoded = jsonDecode(entry.value);
      } on FormatException {
        skip('unreadable card data for one course');
        continue;
      }
      if (decoded is! Map<String, dynamic>) {
        skip('unreadable card data for one course');
        continue;
      }
      for (final item in decoded.entries) {
        final v = item.value;
        if (v is! Map<String, dynamic>) {
          skip('malformed card entry');
          continue;
        }
        final ease = v['ease'];
        final intervalDays = v['intervalDays'];
        final dueEpochDay = v['dueEpochDay'];
        final reps = v['reps'];
        final lapses = v['lapses'];
        if (ease is! num ||
            intervalDays is! int ||
            dueEpochDay is! int ||
            reps is! int ||
            lapses is! int) {
          skip('malformed card entry');
          continue;
        }
        cardRows.add({
          'profileId': profileId,
          'courseId': entry.key,
          'itemId': item.key,
          // SM-2 state, 1:1 — same names, same units.
          'ease': ease.toDouble(),
          'intervalDays': intervalDays,
          'dueEpochDay': dueEpochDay,
          'reps': reps,
          'lapses': lapses,
        });
      }
    }

    final tables = <String, List<Map<String, Object?>>>{
      for (final name in espalierBackupTables) name: const [],
    };
    tables['courses'] = courseRows;
    tables['cards'] = cardRows;

    final imported = <String, int>{
      if (courseRows.isNotEmpty) 'courses': courseRows.length,
      if (cardRows.isNotEmpty) 'cards': cardRows.length,
    };

    return TrellisImportResult(
      tables: tables,
      report: MigrationReport(
        imported: imported,
        skipped: skipped,
        dropped: const [
          'Trellis kept no review log, so imported cards begin with an '
              'empty history — future reviews build it here.',
        ],
      ),
    );
  }

  /// Validates the donor's fleet-envelope JSON (`{app:'trellis',
  /// schemaVersion, payload}`) and requires the three collections every
  /// donor backup ever written carries (donor `_requirePayload`).
  static Map<String, dynamic> _unwrapDonorEnvelope(Uint8List plaintext) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(plaintext));
    } on FormatException {
      throw const FormatException('Backup payload is not valid JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Backup payload is not a JSON object');
    }
    final app = decoded['app'];
    if (app != trellisAppDomain) {
      throw FormatException(
          "Not a Trellis backup (app='${app ?? 'missing'}')");
    }
    final version = decoded['schemaVersion'];
    if (version is! int) {
      throw const FormatException('Missing schemaVersion in backup envelope');
    }
    if (version > _donorSchemaVersion) {
      throw FormatException(
          'This Trellis backup uses schema v$version, newer than this '
          'importer understands (v$_donorSchemaVersion)');
    }
    final payload = decoded['payload'];
    final map = payload is Map<String, dynamic> ? payload : decoded;
    if (map['importedIds'] is! List ||
        map['courses'] is! Map ||
        map['cards'] is! Map) {
      throw const FormatException('Missing payload in backup file');
    }
    return map;
  }

  static List<String> _stringList(Object? v) =>
      (v is List) ? v.whereType<String>().toList() : const [];

  static Map<String, String> _stringMap(Object? v) {
    if (v is! Map) return const {};
    final out = <String, String>{};
    for (final entry in v.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is String && value is String) out[key] = value;
    }
    return out;
  }
}
