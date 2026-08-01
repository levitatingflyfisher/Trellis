import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';

/// The speak-voice preference (ADR-0006's settings escape): a profile-scoped
/// bool, false by default — the same "on-device state the reader already
/// persists" surface as Positions, never a second prefs mechanism.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('a fresh profile defaults to false — neural whenever one is on-device',
      () async {
    final profileId = await db.profilesDao.create('Ada');
    expect(await db.profilesDao.preferSystemVoice(profileId), isFalse);
  });

  test('setting it true persists across reads, scoped to this profile only',
      () async {
    final ada = await db.profilesDao.create('Ada');
    final bea = await db.profilesDao.create('Bea');

    await db.profilesDao.setPreferSystemVoice(ada, true);

    expect(await db.profilesDao.preferSystemVoice(ada), isTrue);
    expect(await db.profilesDao.preferSystemVoice(bea), isFalse,
        reason: 'the preference is per-profile, never global');
  });

  test('flipping it back to false persists too', () async {
    final profileId = await db.profilesDao.create('Ada');
    await db.profilesDao.setPreferSystemVoice(profileId, true);
    await db.profilesDao.setPreferSystemVoice(profileId, false);
    expect(await db.profilesDao.preferSystemVoice(profileId), isFalse);
  });
}
