import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/profiles/parent_pin.dart';

/// The parent-PIN algebra (P5). Laws under test:
///
/// - The database keeps a per-household random salt and a salted SHA-256
///   digest — never the PIN itself.
/// - Set, change and remove all require the current PIN once one exists.
///   There is no recovery path in the API at all: forgetting the PIN means
///   clearing the app's data, and nothing here can shortcut that.
/// - An unset PIN verifies nothing (the gate helper, not this service,
///   decides that an unset PIN means the door is open).
void main() {
  late AppDatabase db;
  late ParentPinService pin;
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    pin = ParentPinService(db);
  });
  tearDown(() => db.close());

  test('unset: isSet is false and nothing verifies', () async {
    expect(await pin.isSet, isFalse);
    expect(await pin.verify('1234'), isFalse);
  });

  test('enable stores salt + digest, never the PIN itself', () async {
    await pin.enable('1234');

    expect(await pin.isSet, isTrue);
    expect(await pin.verify('1234'), isTrue);
    expect(await pin.verify('4321'), isFalse);

    final row = await db.householdDao.readPin();
    expect(row, isNotNull);
    expect(row!.salt, hasLength(32), reason: '16 random bytes, hex');
    expect(row.hash, isNot(contains('1234')));
    expect(row.salt, isNot(contains('1234')));
    expect(row.hash, sha256.convert(utf8.encode('${row.salt}:1234')).toString(),
        reason: 'the digest is exactly salted SHA-256, reproducible');
  });

  test('the salt is per-household random: same PIN, different digests',
      () async {
    final otherDb = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(otherDb.close);
    final other = ParentPinService(otherDb);

    await pin.enable('1234');
    await other.enable('1234');

    final a = (await db.householdDao.readPin())!;
    final b = (await otherDb.householdDao.readPin())!;
    expect(a.salt, isNot(b.salt));
    expect(a.hash, isNot(b.hash));
  });

  test('enable refuses when a PIN already exists — change is the only door',
      () async {
    await pin.enable('1234');
    expect(() => pin.enable('9999'), throwsStateError);
    expect(await pin.verify('1234'), isTrue, reason: 'nothing changed');
  });

  test('change requires the current PIN and rotates the salt', () async {
    await pin.enable('1234');
    final before = (await db.householdDao.readPin())!;

    expect(await pin.change(current: 'wrong', next: '9999'), isFalse);
    expect(await pin.verify('1234'), isTrue, reason: 'a wrong guess changes '
        'nothing');

    expect(await pin.change(current: '1234', next: '9999'), isTrue);
    expect(await pin.verify('9999'), isTrue);
    expect(await pin.verify('1234'), isFalse);
    expect((await db.householdDao.readPin())!.salt, isNot(before.salt),
        reason: 'a fresh salt with every write');
  });

  test('disable requires the current PIN', () async {
    await pin.enable('1234');

    expect(await pin.disable(current: 'wrong'), isFalse);
    expect(await pin.isSet, isTrue);

    expect(await pin.disable(current: '1234'), isTrue);
    expect(await pin.isSet, isFalse);
    expect(await pin.verify('1234'), isFalse);
  });
}
