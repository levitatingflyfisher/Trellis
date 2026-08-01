import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' show sha256;

import '../../db/database.dart';

/// The optional household parent PIN (P5). Storage is one database row of
/// (salt, digest) — see [HouseholdPin]; this service owns the algebra:
///
/// - digest = SHA-256 over `salt:pin`, with 16 random bytes of salt per
///   household ([Random.secure]), so equal PINs in different households
///   never share a digest and a leaked backup gets no rainbow-table head
///   start. Pure Dart (package:crypto) — identical on web.
/// - Set, change and remove all require the current PIN once one exists.
///   There is deliberately NO recovery path anywhere in this API: a
///   forgotten PIN can only be cleared by clearing the app's data, and the
///   UI says so honestly (a backdoor would make the gate a fiction).
/// - What the PIN gates is profile create/delete/rename and the parent
///   dashboard — never reading, playing or studying. A kid can always use
///   their own profile; sovereignty is for the reader too (ADR-0003).
class ParentPinService {
  ParentPinService(this.db, {Random? random})
      : _random = random ?? Random.secure();

  final AppDatabase db;
  final Random _random;

  Future<bool> get isSet async => await db.householdDao.readPin() != null;

  /// True only when a PIN is set and [pin] is it. An unset PIN verifies
  /// nothing — the gate helper, not this service, decides that unset means
  /// the door is open.
  Future<bool> verify(String pin) async {
    final row = await db.householdDao.readPin();
    if (row == null) return false;
    return digest(salt: row.salt, pin: pin) == row.hash;
  }

  /// First-time set. Throws when a PIN already exists — changing it goes
  /// through [change] with the current PIN.
  Future<void> enable(String pin) async {
    if (await isSet) {
      throw StateError(
          'a PIN is already set; changing it requires the current PIN');
    }
    await _write(pin);
  }

  /// Returns false — and changes nothing — unless [current] verifies.
  Future<bool> change({required String current, required String next}) async {
    if (!await verify(current)) return false;
    await _write(next);
    return true;
  }

  /// Returns false — and removes nothing — unless [current] verifies.
  Future<bool> disable({required String current}) async {
    if (!await verify(current)) return false;
    await db.householdDao.clearPin();
    return true;
  }

  /// Every write mints a fresh salt, so even re-using an old PIN produces a
  /// new digest.
  Future<void> _write(String pin) async {
    final salt = newSalt(_random);
    await db.householdDao
        .writePin(salt: salt, hash: digest(salt: salt, pin: pin));
  }

  /// 16 random bytes, hex-encoded.
  static String newSalt(Random random) => [
        for (var i = 0; i < 16; i++)
          random.nextInt(256).toRadixString(16).padLeft(2, '0')
      ].join();

  static String digest({required String salt, required String pin}) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();
}
