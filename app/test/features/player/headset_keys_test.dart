import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/headset_keys.dart';

/// What a headset's keys do (1.6.0, user: "Double tap is skip forward 30
/// seconds. Triple tap is skip forward episode."). The phone is told
/// "Next" or "Previous", never "double tap"; one setting per key.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('until chosen: Next skips forward 30 seconds, Previous goes to the '
      'next episode, and clicks are not counted', () async {
    final keys = await HeadsetKeysStore(db).read();
    expect(keys.next, HeadsetAction.forward30);
    expect(keys.previous, HeadsetAction.nextEpisode);
    expect(keys.countClicks, isFalse,
        reason: 'counting makes play and pause wait a moment; only a '
            'one-button headset needs it');
  });

  test('each choice is remembered on its own', () async {
    final store = HeadsetKeysStore(db);
    await store.setNext(HeadsetAction.back15);
    await store.setPrevious(HeadsetAction.previousEpisode);
    await store.setCountClicks(true);

    final keys = await HeadsetKeysStore(db).read();
    expect(keys.next, HeadsetAction.back15);
    expect(keys.previous, HeadsetAction.previousEpisode);
    expect(keys.countClicks, isTrue);
  });

  test('a stored value this version does not know falls back to the '
      'default, never a crash', () async {
    await db.deviceSettingsDao.write(HeadsetKeysStore.nextKey, 'teleport');
    final keys = await HeadsetKeysStore(db).read();
    expect(keys.next, HeadsetAction.forward30);
  });

  test('the six choices, in the order the owner named them, each with how '
      'far it moves', () {
    expect(HeadsetAction.values.map((a) => a.label), [
      'Skip forward 30 seconds',
      'Skip back 10 seconds',
      'Skip back 15 seconds',
      'Skip back 30 seconds',
      'Next episode',
      'Previous episode',
    ]);
    expect(HeadsetAction.forward30.seekBy, const Duration(seconds: 30));
    expect(HeadsetAction.back10.seekBy, const Duration(seconds: -10));
    expect(HeadsetAction.back15.seekBy, const Duration(seconds: -15));
    expect(HeadsetAction.back30.seekBy, const Duration(seconds: -30));
    expect(HeadsetAction.nextEpisode.seekBy, isNull);
    expect(HeadsetAction.previousEpisode.seekBy, isNull);
  });
}
