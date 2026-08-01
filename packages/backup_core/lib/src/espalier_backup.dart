import 'dart:typed_data';

import 'package:sanctuary_auth_core/sanctuary_auth_core.dart';

/// The app's HKDF `appDomain` — ONE line, renames with the app.
/// (App-level naming is provisional per AGENTS.md; every derived key changes
/// if this changes, so it must be settled before first public release.)
const String espalierAppDomain = 'espalier';

/// AAD context label bound into the AEAD tag of every backup this app writes.
/// A blob made for any other context (another app, a sync dump) fails closed.
const String espalierAadContext = '$espalierAppDomain-backup/v1';

/// Encrypt/decrypt this app's backup payload with the real sanctuary crypto:
/// BIP39 phrase -> PBKDF2 seed -> HKDF (appDomain-separated) master key ->
/// ChaCha20-Poly1305 OHBK envelope with [espalierAadContext] as AAD.
abstract final class EspalierBackup {
  /// Encrypts [payload] (see `RowPayload.encode`) under [phrase].
  ///
  /// Throws [ArgumentError] for an invalid BIP39 phrase.
  static Future<Uint8List> encrypt(Uint8List payload,
      {required String phrase}) async {
    final key = await _masterKey(phrase);
    return GhostBackup.export(
      payload,
      key,
      EnvelopeCipher(),
      context: espalierAadContext,
    );
  }

  /// Decrypts an OHBK [blob] made by [encrypt] under the same [phrase].
  ///
  /// Fails closed: a wrong phrase, a tampered byte, or a blob made under any
  /// other appDomain/AAD context throws `CryptoException` — no partial
  /// plaintext ever escapes. A structurally invalid blob throws
  /// `BackupFormatException`.
  static Future<Uint8List> decrypt(Uint8List blob,
      {required String phrase}) async {
    final key = await _masterKey(phrase);
    return GhostBackup.import(
      blob,
      key,
      EnvelopeCipher(),
      context: espalierAadContext,
    );
  }

  static Future<Uint8List> _masterKey(String phrase) async {
    final seed = await OpenHearthMnemonic.deriveSeed(phrase);
    final keys =
        await KeyDerivation.fromSeed(seed, appDomain: espalierAppDomain);
    return keys.masterEncryptionKey;
  }
}
