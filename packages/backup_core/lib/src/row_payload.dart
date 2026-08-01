import 'dart:convert';
import 'dart:typed_data';

import 'espalier_backup.dart';

/// The tables of one backup payload: table name -> ordered row maps.
///
/// DB-agnostic on purpose — the storage adapter (Drift native or drift-wasm)
/// decides how rows become SQL; this package never sees a database.
typedef RowTables = Map<String, List<Map<String, Object?>>>;

/// The canonical table set of the backup payload, in canonical order.
///
/// `consents` is deliberately NOT here and can never be added by accident:
/// both [RowPayload.encode] and [RowPayload.decode] fail closed on it —
/// consents never travel (ADR-0003 law 6: consent is per-device, re-asked).
const List<String> espalierBackupTables = [
  'profiles',
  'works',
  'segments',
  'layers',
  'alignments',
  'positions',
  'feeds',
  'courses',
  'cards',
  'revlog',
  'playerPositions',
];

/// The one table name that must never appear in a payload, in or out.
const String _forbiddenTable = 'consents';

/// The decoded result of [RowPayload.decode].
class DecodedPayload {
  final int schemaVersion;
  final DateTime? createdAt;

  /// Always carries every table in [espalierBackupTables]; tables absent
  /// from the file decode as empty lists.
  final RowTables tables;

  const DecodedPayload({
    required this.schemaVersion,
    required this.createdAt,
    required this.tables,
  });
}

/// Versioned JSON payload of DB-agnostic row maps — the plaintext that goes
/// inside the encrypted OHBK envelope.
///
/// The JSON is the fleet-standard envelope shape
/// `{app, schemaVersion, createdAt, payload}` (sanctuary_backup_ui
/// `BackupEnvelope`), so the shared preview/restore UI can describe our
/// backups without special-casing. The `app` stamp is defense in depth — the
/// AEAD context already cryptographically binds the blob to this app.
abstract final class RowPayload {
  /// Bumped only when the payload shape changes in a way an older running
  /// app could not restore correctly.
  static const int schemaVersion = 1;

  /// Encodes [tables] as envelope JSON in UTF-8 bytes.
  ///
  /// Tables omitted from [tables] are written as empty lists so every backup
  /// carries the full canonical shape. Throws [ArgumentError] on a
  /// `consents` table (consents never travel) or any unknown table name
  /// (no silent schema drift).
  static Uint8List encode(RowTables tables, {required DateTime createdAt}) {
    for (final name in tables.keys) {
      if (name == _forbiddenTable) {
        throw ArgumentError.value(
          name,
          'tables',
          'consents never travel — they are re-asked on the target device',
        );
      }
      if (!espalierBackupTables.contains(name)) {
        throw ArgumentError.value(name, 'tables', 'unknown backup table');
      }
    }
    final payload = <String, Object?>{
      for (final name in espalierBackupTables) name: tables[name] ?? const [],
    };
    final envelope = <String, Object?>{
      'app': espalierAppDomain,
      'schemaVersion': schemaVersion,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'payload': payload,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
  }

  /// Decodes and validates bytes produced by [encode].
  ///
  /// Throws [FormatException] for non-JSON bytes, a payload stamped for
  /// another app, a schemaVersion newer than this build understands, a
  /// missing/malformed payload, or a payload containing a `consents` table
  /// (fail closed — a foreign or tampered file never half-imports).
  static DecodedPayload decode(Uint8List bytes) {
    final Object? root;
    try {
      root = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const FormatException('Backup payload is not valid JSON');
    }
    if (root is! Map<String, dynamic>) {
      throw const FormatException('Backup payload is not a JSON object');
    }

    final app = root['app'];
    if (app != espalierAppDomain) {
      throw FormatException(
          "Not a backup for this app (app='${app ?? 'missing'}')");
    }

    final version = root['schemaVersion'];
    if (version is! int) {
      throw const FormatException('Missing schemaVersion in backup envelope');
    }
    if (version > schemaVersion) {
      throw FormatException(
          'Backup schema v$version is newer than this app understands '
          '(v$schemaVersion) — update the app, then restore');
    }

    final payload = root['payload'];
    if (payload is! Map<String, dynamic>) {
      throw const FormatException('Missing payload in backup file');
    }
    if (payload.containsKey(_forbiddenTable)) {
      throw const FormatException(
          'Backup contains a consents table; consents never travel — '
          'refusing to import');
    }

    final tables = <String, List<Map<String, Object?>>>{};
    for (final name in espalierBackupTables) {
      final raw = payload[name];
      if (raw == null) {
        tables[name] = const [];
        continue;
      }
      if (raw is! List) {
        throw FormatException("Backup table '$name' is not a list");
      }
      tables[name] = [
        for (final row in raw)
          if (row is Map<String, dynamic>)
            row.cast<String, Object?>()
          else
            throw FormatException("Backup table '$name' holds a non-map row"),
      ];
    }

    final createdRaw = root['createdAt'];
    final created =
        createdRaw is String ? DateTime.tryParse(createdRaw)?.toUtc() : null;

    return DecodedPayload(
      schemaVersion: version,
      createdAt: created,
      tables: tables,
    );
  }
}
