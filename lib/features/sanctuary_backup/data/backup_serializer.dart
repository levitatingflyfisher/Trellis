import 'dart:typed_data';

import 'package:sanctuary_backup_ui/sanctuary_backup_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../curriculum/data/course_repository.dart';
import '../../study/data/card_repository.dart';

/// Serializes Trellis's user data to/from a JSON [Uint8List] for encrypted
/// backup via `sanctuary_backup_ui`.
///
/// Works directly with the app's [SharedPreferences] instance — not through
/// [CourseRepository]/[CardRepository] — mirroring Lullaby's precedent of
/// bypassing any filtered repository layer for a full-store dump (this app
/// has no Drift database; shared_preferences key/value pairs are the entire
/// persistence layer, per ADR-0002).
///
/// **Backup scope** (SANCTUARY-BRIEF §4.W2 app-specific block): bundled
/// courses ship inside the app and are never dumped, but a user's SM-2 study
/// *progress* against a bundled course is theirs and must survive a restore
/// — so cards are dumped for every course id that has a `cards:` key,
/// bundled or imported, while course *content* is dumped only for imported
/// ids (`imported_ids` + `course:<id>`).
///
/// The JSON envelope is the fleet-standard [BackupEnvelope] shape
/// `{app, schemaVersion, createdAt, payload}` — `createdAt` is ADDITIVE on
/// top of the `{app, schemaVersion, payload}` shape Trellis shipped, so old
/// installs (which read only those three keys) keep restoring new backups,
/// and [BackupEnvelope.unwrap]'s tolerant parse keeps old backups restoring
/// here. The envelope lets [restoreAll] reject a backup made for a different
/// app or a future schema version — defense in depth behind the AEAD context
/// that already scopes the encrypted blob to this app (SANCTUARY-BRIEF §2.3,
/// §2.8).
class TrellisBackupSerializer
    implements BackupSerializer, PreviewableBackupSerializer {
  final SharedPreferences _prefs;

  const TrellisBackupSerializer(this._prefs);

  static const String _appId = 'trellis';

  /// Bumped only if the shape of the payload below ever changes in a way an
  /// older running app couldn't restore correctly.
  static const int _schemaVersion = 1;

  @override
  Future<Uint8List> dumpAll() async {
    final importedIds =
        _prefs.getStringList(CourseRepository.indexKey) ?? const [];

    final courses = <String, String>{};
    for (final id in importedIds) {
      final raw = _prefs.getString(CourseRepository.courseKey(id));
      if (raw != null) courses[id] = raw;
    }

    final cards = <String, String>{};
    for (final k in _prefs.getKeys()) {
      if (!k.startsWith(CardRepository.keyPrefix)) continue;
      final raw = _prefs.getString(k);
      if (raw == null) continue;
      cards[k.substring(CardRepository.keyPrefix.length)] = raw;
    }

    // The shared fleet envelope (BACKUP_RETENTION_SPEC §2.F): identical to
    // the hand-rolled shape this replaced plus createdAt, which feeds
    // preview-before-restore and staleness copy.
    return BackupEnvelope.wrap(
      appId: _appId,
      schemaVersion: _schemaVersion,
      createdAt: DateTime.now(),
      payload: {
        'importedIds': importedIds,
        'courses': courses,
        'cards': cards,
      },
    );
  }

  /// The dry-run parse behind preview-before-restore and export
  /// verify-by-read-back: validates exactly like [restoreAll] (wrong app,
  /// future schema, malformed payload) and reports the manifest — but never
  /// writes.
  @override
  Future<BackupManifest> describeBackup(Uint8List plaintext) async {
    _requirePayload(_unwrap(plaintext).payload); // throws what restoreAll would
    return BackupEnvelope.describe(plaintext);
  }

  /// The payload-content gate [restoreAll] applies — shared so describe and
  /// restore can never drift apart. Every backup Trellis ever wrote carries
  /// all three collections, so requiring them costs no compatibility; it is
  /// what turns unwrap's "whole envelope as payload" fallback back into the
  /// missing-payload rejection this app always had.
  static void _requirePayload(Map<String, Object?> payload) {
    if (payload['importedIds'] is! List ||
        payload['courses'] is! Map ||
        payload['cards'] is! Map) {
      throw const FormatException('Missing payload in backup file');
    }
  }

  /// Envelope validation via the shared helper. Trellis has always stamped
  /// the `app` key, so the strict default (`requireAppKey: true`) keeps the
  /// missing-app rejection the shipped app enforced.
  UnwrappedBackup _unwrap(Uint8List data) => BackupEnvelope.unwrap(
        data,
        expectedAppId: _appId,
        currentSchemaVersion: _schemaVersion,
      );

  /// Restores all user data from an OHBK envelope previously produced by
  /// [dumpAll].
  ///
  /// **Destructive:** every existing `imported_ids`/`course:*`/`cards:*` key
  /// is removed before the backup's keys are written back — no key from
  /// before the restore survives unless the backup also contains it. Course
  /// and card payloads are restored as the exact raw JSON strings [dumpAll]
  /// read (no re-parse/re-serialize round trip), so a restore can never
  /// subtly rewrite content the export captured faithfully.
  ///
  /// shared_preferences has no cross-key transaction primitive, so this is
  /// *not* atomic against a crash mid-restore the way a Drift transaction
  /// would be — the write order (course/card data, then the `imported_ids`
  /// index last) is chosen so a reader that trusts the index never observes
  /// an id with missing data.
  ///
  /// Throws [FormatException] for a malformed envelope, a missing/mismatched
  /// `app`, or a missing `payload`/`schemaVersion`. Throws
  /// [BackupSchemaException] when the payload's schema version is newer than
  /// this app understands.
  @override
  Future<void> restoreAll(Uint8List data) async {
    final payload = _unwrap(data).payload;
    _requirePayload(payload);

    final importedIds = _stringList(payload['importedIds']);
    final courses = _stringMap(payload['courses']);
    final cards = _stringMap(payload['cards']);

    // Wipe every key this serializer owns before writing the backup back —
    // a key present now but absent from the backup must not survive.
    for (final key in _prefs.getKeys().toList()) {
      if (key == CourseRepository.indexKey ||
          key.startsWith(CourseRepository.coursePrefix) ||
          key.startsWith(CardRepository.keyPrefix)) {
        await _prefs.remove(key);
      }
    }

    for (final entry in courses.entries) {
      await _prefs.setString(
          CourseRepository.courseKey(entry.key), entry.value);
    }
    for (final entry in cards.entries) {
      await _prefs.setString(CardRepository.key(entry.key), entry.value);
    }
    // Index last: only valid once every id it names already has its data.
    await _prefs.setStringList(CourseRepository.indexKey, importedIds);
  }

  List<String> _stringList(Object? v) =>
      (v is List) ? v.whereType<String>().toList() : const [];

  Map<String, String> _stringMap(Object? v) {
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
