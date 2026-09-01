/// Where this app's confirmed recovery phrase lives between backups — the
/// fleet's key model (controller ruling, follow-up to trellis:doet-04): the
/// phrase is kept on the device once it has been confirmed, so a backup
/// never asks for it again; restore and import on a new device still do.
///
/// Custody law (the brain_store precedent): the phrase lives ONLY in the
/// OS keychain behind the fleet's own [SecureKeyStore] — never the
/// database, never prefs, never a backup file. A keychain that cannot be
/// read behaves as "no phrase yet": the screen falls back to asking.
library;

import 'dart:async';

import 'package:backup_core/backup_core.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sanctuary_backup_ui/sanctuary_backup_ui.dart'
    show AppScopedSecureKeyStore;
import 'package:sanctuary_auth_core/sanctuary_auth_core.dart';

/// The narrow seam: widget tests inject [MemoryBackupCustody] and never
/// touch the plugin channel (an unmocked secure-storage read hangs rather
/// than throws under flutter test).
abstract interface class BackupCustody {
  /// The confirmed phrase kept on this device, or null when there is none
  /// (or the keychain can't be read).
  Future<String?> readPhrase();

  /// A valid phrase already on the device but never acknowledged — e.g.
  /// written by the donor Trellis (sanctuary_backup_ui writes the phrase
  /// before its ask-back) and inherited by an in-place upgrade. Its backups
  /// exist, so it is offered back, never replaced.
  Future<String?> readUnconfirmedPhrase();

  /// Keeps [phrase] as this app's confirmed recovery phrase. Call only
  /// after the user has proven they hold it (shown and asked back, or
  /// typed twice). Throws [StateError] rather than replace a DIFFERENT
  /// phrase already on the device — the sanctuary rule
  /// (`generateSeedPhrase` refuses to overwrite without `force`).
  Future<void> savePhrase(String phrase);

  /// Whether the "finish setup" reminder was dismissed on this device.
  Future<bool> reminderDismissed();

  /// Dismisses the "finish setup" reminder on this device.
  Future<void> dismissReminder();

  /// Records when a checked backup was last saved (fleet parity:
  /// [SecureKeyStore.writeLastBackupAt]).
  Future<void> recordBackup(DateTime at);
}

/// Production custody over the fleet's [SecureKeyStore] (the same
/// `oh_mnemonic_v1` / `oh_seed_ack_v1` keys the sanctuary_backup_ui apps
/// use) plus one app flag for the dismissed reminder.
class SecureBackupCustody implements BackupCustody {
  SecureBackupCustody({SecureKeyStore? keys, FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage(),
      _keys = keys ?? FlutterSecureKeyStore(storage);

  /// The PWA's custody. Every fleet PWA is served from one origin and so
  /// shares one localStorage; the app-scoped store keeps Trellis's words,
  /// acknowledgement and backup time under `oh_trellis_…` so another fleet
  /// app's words are never taken for this app's (sanctuary_backup_ui
  /// 0.3.0). Native keychains are per app already.
  SecureBackupCustody.web()
    : this(keys: AppScopedSecureKeyStore(appId: 'trellis'));

  final SecureKeyStore _keys;
  final FlutterSecureStorage _storage;

  @visibleForTesting
  SecureKeyStore get keys => _keys;

  /// Reads are deadline-bound for the same reason brain_store's are: an
  /// absent platform implementation hangs the channel instead of throwing.
  static const Duration _readDeadline = Duration(seconds: 5);

  static const _kReminderDismissed = 'oh_trellis_setup_reminder_dismissed_v1';

  @override
  Future<String?> readPhrase() async {
    try {
      if (!await _keys.readSeedAcknowledged().timeout(_readDeadline)) {
        return null;
      }
      final phrase = await _keys.readMnemonic().timeout(_readDeadline);
      if (phrase == null || !EspalierBackup.isValidPhrase(phrase)) return null;
      return phrase;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> readUnconfirmedPhrase() async {
    try {
      if (await _keys.readSeedAcknowledged().timeout(_readDeadline)) {
        return null;
      }
      final phrase = await _keys.readMnemonic().timeout(_readDeadline);
      if (phrase == null || !EspalierBackup.isValidPhrase(phrase)) return null;
      return phrase;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> savePhrase(String phrase) async {
    // An unreadable keychain throws here too (timeout): never write blind
    // over something that could not be checked.
    final existing = await _keys.readMnemonic().timeout(_readDeadline);
    if (existing != null && EspalierBackup.isValidPhrase(existing)) {
      if (_same(existing, phrase)) {
        await _keys.writeSeedAcknowledged();
        return;
      }
      throw StateError('A different recovery phrase is already kept on this '
          'device; it is never overwritten.');
    }
    await _keys.writeMnemonic(phrase);
    await _keys.writeSeedAcknowledged();
  }

  static bool _same(String a, String b) {
    String norm(String p) =>
        p.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');
    return norm(a) == norm(b);
  }

  @override
  Future<bool> reminderDismissed() async {
    try {
      return await _storage
              .read(key: _kReminderDismissed)
              .timeout(_readDeadline) ==
          'true';
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> dismissReminder() =>
      _storage.write(key: _kReminderDismissed, value: 'true');

  @override
  Future<void> recordBackup(DateTime at) => _keys.writeLastBackupAt(at);
}

/// In-memory custody: what tests inject, seeded or empty.
class MemoryBackupCustody implements BackupCustody {
  MemoryBackupCustody({this.phrase, this.dismissed = false});

  String? phrase;
  bool dismissed;
  DateTime? lastBackupAt;

  @override
  Future<String?> readPhrase() async => phrase;

  @override
  Future<String?> readUnconfirmedPhrase() async => null;

  @override
  Future<void> savePhrase(String phrase) async => this.phrase = phrase;

  @override
  Future<bool> reminderDismissed() async => dismissed;

  @override
  Future<void> dismissReminder() async => dismissed = true;

  @override
  Future<void> recordBackup(DateTime at) async => lastBackupAt = at;
}
