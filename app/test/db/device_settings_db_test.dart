import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';

/// Device-level settings: not a reader's, the device's. The theme choice
/// and which reader was last active live here, one row per key.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('an unset key reads null; a set one round-trips and can change',
      () async {
    final dao = db.deviceSettingsDao;
    expect(await dao.read('theme_mode'), isNull);
    await dao.write('theme_mode', 'dark');
    expect(await dao.read('theme_mode'), 'dark');
    await dao.write('theme_mode', 'light');
    expect(await dao.read('theme_mode'), 'light');
  });

  test('the last active reader round-trips and can be cleared', () async {
    final dao = db.deviceSettingsDao;
    expect(await dao.lastProfileId(), isNull);
    final ada = await db.profilesDao.create('Ada');
    await dao.setLastProfileId(ada);
    expect(await dao.lastProfileId(), ada);
    await dao.setLastProfileId(null);
    expect(await dao.lastProfileId(), isNull);
  });
}
