import 'dart:convert';
import 'dart:typed_data';

import 'package:backup_core/backup_core.dart';
import 'package:sanctuary_auth_core/sanctuary_auth_core.dart';
import 'package:test/test.dart';

/// Standard BIP39 test vectors — real phrases, real derivation, no mocks.
const phrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon about';
const otherPhrase =
    'legal winner thank year wave sausage worth useful legal winner '
    'thank yellow';

RowTables sampleTables() => {
      'profiles': [
        {'id': 'p1', 'name': 'Reader'},
      ],
      'works': [
        {'id': 'p1::walden.epub::4242', 'profileId': 'p1', 'kind': 'book'},
      ],
      'cards': [
        {
          'courseId': 'course-1',
          'itemId': 'item-1',
          'ease': 2.5,
          'intervalDays': 6,
          'dueEpochDay': 20670,
          'reps': 2,
          'lapses': 0,
        },
      ],
    };

void main() {
  group('constants', () {
    test('appDomain is the one-line rename point and the AAD derives from it',
        () {
      expect(espalierAppDomain, 'espalier');
      expect(espalierAadContext, 'espalier-backup/v1');
    });
  });

  group('RowPayload', () {
    test('encode -> decode round-trips every canonical table', () {
      final created = DateTime.utc(2026, 8, 6, 12);
      final bytes = RowPayload.encode(sampleTables(), createdAt: created);
      final decoded = RowPayload.decode(bytes);

      expect(decoded.schemaVersion, RowPayload.schemaVersion);
      expect(decoded.createdAt, created);
      // Every canonical table is present; omitted ones decode as empty.
      expect(decoded.tables.keys.toSet(), espalierBackupTables.toSet());
      expect(decoded.tables['profiles'], [
        {'id': 'p1', 'name': 'Reader'},
      ]);
      expect(decoded.tables['cards']!.single['ease'], 2.5);
      expect(decoded.tables['revlog'], isEmpty);
      expect(decoded.tables['playerPositions'], isEmpty);
    });

    test('encoded JSON is the fleet envelope shape stamped with the app id',
        () {
      final bytes =
          RowPayload.encode(sampleTables(), createdAt: DateTime.utc(2026));
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      expect(json['app'], espalierAppDomain);
      expect(json['schemaVersion'], RowPayload.schemaVersion);
      expect(json['createdAt'], '2026-01-01T00:00:00.000Z');
      expect(json['payload'], isA<Map<String, dynamic>>());
    });

    test('consents NEVER travel: encode refuses a consents table', () {
      final tables = sampleTables()
        ..['consents'] = [
          {'key': 'proxy', 'grantedAt': 1}
        ];
      expect(
        () => RowPayload.encode(tables, createdAt: DateTime.utc(2026)),
        throwsArgumentError,
      );
    });

    test('consents NEVER travel: the encoded bytes contain no consents key',
        () {
      final bytes =
          RowPayload.encode(sampleTables(), createdAt: DateTime.utc(2026));
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final payload = json['payload'] as Map<String, dynamic>;
      expect(payload.containsKey('consents'), isFalse);
    });

    test('consents NEVER travel: decode fails closed on a consents table',
        () {
      // A hand-crafted envelope smuggling consents in — decode must refuse,
      // not quietly drop, so a tampered/foreign file never half-imports.
      final crafted = utf8.encode(jsonEncode({
        'app': espalierAppDomain,
        'schemaVersion': RowPayload.schemaVersion,
        'createdAt': '2026-01-01T00:00:00.000Z',
        'payload': {
          'profiles': <Object?>[],
          'consents': [
            {'key': 'proxy'}
          ],
        },
      }));
      expect(
        () => RowPayload.decode(Uint8List.fromList(crafted)),
        throwsFormatException,
      );
    });

    test('encode refuses unknown tables (no silent schema drift)', () {
      final tables = sampleTables()..['mystery'] = [];
      expect(
        () => RowPayload.encode(tables, createdAt: DateTime.utc(2026)),
        throwsArgumentError,
      );
    });

    test('decode rejects a payload for another app', () {
      final crafted = utf8.encode(jsonEncode({
        'app': 'trellis',
        'schemaVersion': 1,
        'payload': {'profiles': <Object?>[]},
      }));
      expect(
        () => RowPayload.decode(Uint8List.fromList(crafted)),
        throwsFormatException,
      );
    });

    test('decode rejects a future schemaVersion', () {
      final crafted = utf8.encode(jsonEncode({
        'app': espalierAppDomain,
        'schemaVersion': RowPayload.schemaVersion + 1,
        'payload': {'profiles': <Object?>[]},
      }));
      expect(
        () => RowPayload.decode(Uint8List.fromList(crafted)),
        throwsFormatException,
      );
    });

    test('decode rejects non-JSON bytes', () {
      expect(
        () => RowPayload.decode(Uint8List.fromList([0, 1, 2, 3])),
        throwsFormatException,
      );
    });
  });

  group('EspalierBackup (real sanctuary crypto)', () {
    test('encrypt -> decrypt round-trips to byte-identical payload',
        () async {
      final payload =
          RowPayload.encode(sampleTables(), createdAt: DateTime.utc(2026));
      final blob = await EspalierBackup.encrypt(payload, phrase: phrase);

      // It really is an OHBK blob, and really is ciphertext.
      expect(blob.sublist(0, 4), [0x4F, 0x48, 0x42, 0x4B]); // "OHBK"
      expect(blob.length, greaterThan(payload.length));

      final roundTripped = await EspalierBackup.decrypt(blob, phrase: phrase);
      expect(roundTripped, orderedEquals(payload));
    });

    test('wrong phrase fails closed', () async {
      final payload =
          RowPayload.encode(sampleTables(), createdAt: DateTime.utc(2026));
      final blob = await EspalierBackup.encrypt(payload, phrase: phrase);
      expect(
        () => EspalierBackup.decrypt(blob, phrase: otherPhrase),
        throwsA(isA<CryptoException>()),
      );
    });

    test('a tampered ciphertext byte fails closed', () async {
      final payload =
          RowPayload.encode(sampleTables(), createdAt: DateTime.utc(2026));
      final blob = await EspalierBackup.encrypt(payload, phrase: phrase);
      final tampered = Uint8List.fromList(blob);
      tampered[tampered.length - 1] ^= 0x01;
      expect(
        () => EspalierBackup.decrypt(tampered, phrase: phrase),
        throwsA(isA<CryptoException>()),
      );
    });

    test('a blob bound to a different AAD context fails closed even under '
        'the correct key', () async {
      // Same phrase, same appDomain-derived key — only the AAD context
      // differs. AEAD must reject the substitution.
      final seed = await OpenHearthMnemonic.deriveSeed(phrase);
      final keys =
          await KeyDerivation.fromSeed(seed, appDomain: espalierAppDomain);
      final foreign = await GhostBackup.export(
        RowPayload.encode(sampleTables(), createdAt: DateTime.utc(2026)),
        keys.masterEncryptionKey,
        EnvelopeCipher(),
        context: 'espalier-sync/v1',
      );
      expect(
        () => EspalierBackup.decrypt(foreign, phrase: phrase),
        throwsA(isA<CryptoException>()),
      );
    });

    test('a donor-app blob (trellis domain + context) fails closed under '
        'our decrypt', () async {
      final seed = await OpenHearthMnemonic.deriveSeed(phrase);
      final donorKeys =
          await KeyDerivation.fromSeed(seed, appDomain: trellisAppDomain);
      final donorBlob = await GhostBackup.export(
        Uint8List.fromList(utf8.encode('{"app":"trellis"}')),
        donorKeys.masterEncryptionKey,
        EnvelopeCipher(),
        context: trellisAadContext,
      );
      expect(
        () => EspalierBackup.decrypt(donorBlob, phrase: phrase),
        throwsA(isA<CryptoException>()),
      );
    });
  });
}
