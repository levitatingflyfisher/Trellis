/// What a headset's keys do (1.6.0, user: "Double tap is skip forward 30
/// seconds. Triple tap is skip forward episode. And there's a right and
/// left earbud.").
///
/// A tap is turned into a command inside the earbud. The phone is told
/// "Next" or "Previous" (on most earbuds a double and a triple tap), with
/// nothing to say which earbud it came from, so there is one setting per
/// incoming key and none per side. A one-button wired headset sends the
/// same single click every time; counting those clicks is a switch, off
/// until chosen, because it makes play and pause wait a moment to see
/// whether another click follows.
library;

import '../../db/database.dart';

enum HeadsetAction {
  forward30('Skip forward 30 seconds', Duration(seconds: 30)),
  back10('Skip back 10 seconds', Duration(seconds: -10)),
  back15('Skip back 15 seconds', Duration(seconds: -15)),
  back30('Skip back 30 seconds', Duration(seconds: -30)),
  nextEpisode('Next episode', null),
  previousEpisode('Previous episode', null);

  const HeadsetAction(this.label, this.seekBy);

  /// The words in the settings.
  final String label;

  /// How far a skip moves; null for the two that change episode.
  final Duration? seekBy;
}

class HeadsetKeys {
  const HeadsetKeys({
    this.next = HeadsetAction.forward30,
    this.previous = HeadsetAction.nextEpisode,
    this.countClicks = false,
  });

  final HeadsetAction next;
  final HeadsetAction previous;
  final bool countClicks;
}

class HeadsetKeysStore {
  HeadsetKeysStore(this.db);
  final AppDatabase db;

  /// The device's, not a reader's: the headset belongs to the phone.
  static const nextKey = 'headset_next_key';
  static const previousKey = 'headset_previous_key';
  static const countClicksKey = 'headset_count_clicks';

  /// Read on each key press, so a change holds from the next press. A
  /// stored value this version does not know reads as the default.
  Future<HeadsetKeys> read() async {
    const defaults = HeadsetKeys();
    return HeadsetKeys(
      next: _action(await db.deviceSettingsDao.read(nextKey)) ?? defaults.next,
      previous: _action(await db.deviceSettingsDao.read(previousKey)) ??
          defaults.previous,
      countClicks: await db.deviceSettingsDao.read(countClicksKey) == 'on',
    );
  }

  static HeadsetAction? _action(String? name) =>
      HeadsetAction.values.where((a) => a.name == name).firstOrNull;

  Future<void> setNext(HeadsetAction action) =>
      db.deviceSettingsDao.write(nextKey, action.name);

  Future<void> setPrevious(HeadsetAction action) =>
      db.deviceSettingsDao.write(previousKey, action.name);

  Future<void> setCountClicks(bool on) =>
      db.deviceSettingsDao.write(countClicksKey, on ? 'on' : 'off');
}
