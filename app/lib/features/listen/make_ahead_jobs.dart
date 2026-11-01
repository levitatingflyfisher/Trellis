/// The working side of make ahead: the record held in memory while the
/// app runs, the room it takes, and the conditions. It decides nothing
/// about the line; [ListenJobs] asks it what is due, one episode at a
/// time, when nothing a person asked for is left to do.
library;

import 'dart:async';
import 'dart:io';

import '../../db/database.dart';
import '../models/consent.dart';
import '../models/format.dart';
import 'make_ahead.dart';

/// What the show's page shows for its switch.
class MakeAheadOffer {
  const MakeAheadOffer({required this.on, required this.lang, required this.line});

  final bool on;

  /// The learning language; null until one is chosen, and the first
  /// switch-on then asks.
  final String? lang;

  /// What was made for this show and what it takes; null when nothing.
  final String? line;
}

class _Facts {
  const _Facts(this.entry, this.bytes, this.played, this.immune);
  final AheadEntry entry;
  final int bytes;
  final bool played;
  final bool immune;
}

class MakeAhead {
  MakeAhead({
    required this.db,
    required this.conditionsMet,
    required this.modelsNeeded,
    required this.audioFileFor,
    this.askForPass,
    this.watchEvery = const Duration(seconds: 30),
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final AppDatabase db;

  /// Wi-Fi and charging, both, right now. Asked before each episode and
  /// every [watchEvery] while one is being made.
  final Future<bool> Function() conditionsMet;

  /// The models making [work] in [lang] would fetch, for the consent
  /// sheet and for the rule that nothing is fetched without it. With
  /// [forShow] it is asked about the show's future episodes, so a
  /// transcript that happens to exist does not hide the transcriber.
  final Future<List<DownloadItem>> Function(Work work, Episode episode,
      String lang, {required bool forShow}) modelsNeeded;

  final File Function(int workId, String url) audioFileFor;

  /// Asks the system for a pass once the phone is on Wi-Fi and charging.
  final Future<void> Function()? askForPass;

  final Duration watchEvery;
  final int Function() _nowMs;

  AheadBook _book = AheadBook();
  List<_Facts> _facts = const [];
  int _limitBytes = makeAheadLimitBytes(makeAheadDefaultLimitGb);
  Future<void> _writes = Future.value();

  bool isOn(int feedId) => _book.shows.containsKey(feedId);
  bool get anyOn => _book.shows.isNotEmpty;

  /// The language the person agreed to fetch models for on this show.
  String? agreedLang(int feedId) => _book.shows[feedId]?.agreedLang;

  /// Every waiting episode of a show that is on, newest first.
  List<AheadEntry> get waiting => [
        for (final e in _book.entries)
          if (!e.made && isOn(e.feedId)) e,
      ]..sort((a, b) => b.publishedAtMs.compareTo(a.publishedAtMs));

  bool isWaiting(int workId) => waiting.any((e) => e.workId == workId);

  /// Completes once every change so far is written.
  Future<void> get saved => _writes;

  void _save() {
    _writes = _writes.then((_) async {
      try {
        await db.deviceSettingsDao.write(makeAheadKey, _book.encode());
      } catch (_) {
        // The database went away under it: the record stays as it was.
      }
    });
  }

  Future<void> load() async {
    _book = await readAheadBook(db);
    await refreshFacts();
  }

  Future<void> _readLimit() async {
    final gb = int.tryParse(
        await db.deviceSettingsDao.read(makeAheadLimitKey) ?? '');
    _limitBytes = makeAheadLimitBytes(
        gb != null && gb > 0 ? gb : makeAheadDefaultLimitGb);
  }

  /// Turning a show on starts from now: what is already in it is never
  /// made ahead.
  Future<void> switchOn(int feedId, {String? agreedLang}) async {
    var newest = 0;
    for (final e in await db.feedsDao.episodesOfFeed(feedId)) {
      if (e.work.id > newest) newest = e.work.id;
    }
    _book.shows[feedId] = (after: newest, agreedLang: agreedLang);
    _save();
  }

  /// Waiting episodes go with the switch; what was made stays, under the
  /// same limit.
  void switchOff(int feedId) {
    _book.shows.remove(feedId);
    _book.entries.removeWhere((e) => e.feedId == feedId && !e.made);
    _save();
  }

  /// A person asked for [workId] themselves: it is theirs now, so it is
  /// not counted, and never removed for room.
  void takeOver(int workId) => _drop(workId);

  /// Stopped by hand, or impossible: not tried again.
  void drop(int workId) => _drop(workId);

  void _drop(int workId) {
    final before = _book.entries.length;
    _book.entries.removeWhere((e) => e.workId == workId);
    if (_book.entries.length != before) _save();
  }

  void markMade(int workId, int spokenId, String lang) {
    final i = _book.entries.indexWhere((e) => e.workId == workId);
    if (i < 0) return;
    _book.entries[i] = _book.entries[i].madeAs(spokenId, lang, _nowMs());
    _save();
  }

  /// One failure may be the network going; a second is the episode.
  void noteFailure(int workId) {
    final i = _book.entries.indexWhere((e) => e.workId == workId);
    if (i < 0) return;
    final tried = _book.entries[i].withTry();
    if (tried.tries >= 2) {
      _book.entries.removeAt(i);
    } else {
      _book.entries[i] = tried;
    }
    _save();
  }

  /// Before a backup restore: every id here would name something else
  /// afterwards, and consent belongs to this device (as ADR-0018's does).
  void clearAll() {
    _book = AheadBook();
    _facts = const [];
    _save();
  }

  /// Picks what is new in each show that is on. A pick and its show's
  /// mark are one write, so a kill can neither lose one nor pick it twice.
  Future<void> plan({
    required String lang,
    required bool Function(int workId) here,
    required bool Function(Work work, Episode episode, String? feedLang)
        canMake,
  }) async {
    var changed = false;
    for (final feedId in [..._book.shows.keys]) {
      final show = _book.shows[feedId]!;
      final feed = await db.feedsDao.feedById(feedId);
      if (feed == null) {
        _book.shows.remove(feedId);
        changed = true;
        continue;
      }
      final held = _book.entries.where((e) => e.feedId == feedId && !e.made).length +
          _facts
              .where((f) =>
                  f.entry.feedId == feedId &&
                  f.entry.lang == lang &&
                  !f.played)
              .length;
      final room = makeAheadPerShow - held;
      // Full: the mark stays, so the newest can be picked when a slot opens.
      if (room <= 0) continue;
      final episodes = await db.feedsDao.episodesOfFeed(feedId);
      final byId = {for (final e in episodes) e.work.id: e};
      final picks = aheadPicks(episodes,
          afterWorkId: show.after,
          room: room,
          skip: (id) =>
              here(id) ||
              _book.entries.any((e) => e.workId == id) ||
              !canMake(byId[id]!.work, byId[id]!.episode, feed.language));
      var newest = show.after;
      for (final e in episodes) {
        if (e.work.id > newest && !e.episode.guid.startsWith('spoken:')) {
          newest = e.work.id;
        }
      }
      if (newest != show.after || picks.isNotEmpty) {
        _book.entries.addAll(picks);
        _book.shows[feedId] = (after: newest, agreedLang: show.agreedLang);
        changed = true;
      }
    }
    if (changed) _save();
  }

  /// Reads what is on the device for each made episode. A made entry
  /// whose file is gone (the person deleted it on the storage page) is
  /// forgotten: it took no room, and is not made again.
  Future<void> refreshFacts({int? playingId}) async {
    await _readLimit();
    final queued = <int>{};
    for (final p in await db.profilesDao.all()) {
      for (final row in await db.queueDao.queueOf(p.id)) {
        queued.add(row.workId);
      }
    }
    final listening = <int>{
      for (final pos in await db.feedsDao.allPlayerPositions())
        if (pos.tMs > 0) pos.workId,
    };
    final facts = <_Facts>[];
    var forgot = false;
    for (final e in [..._book.entries]) {
      final id = e.spokenId;
      if (id == null) continue;
      final spoken = await db.spineDao.workById(id);
      final episode = await db.feedsDao.episodeOf(id);
      final url = episode?.enclosureUrl;
      final file = url == null ? null : audioFileFor(id, url);
      if (spoken == null || file == null || !file.existsSync()) {
        _book.entries.remove(e);
        forgot = true;
        continue;
      }
      // Kept by the person's hand, on either row: not ours to count or take.
      final original = await db.spineDao.workById(e.workId);
      if (spoken.persistence == 'work' || original?.persistence == 'work') {
        continue;
      }
      final originalEpisode = await db.feedsDao.episodeOf(e.workId);
      final played = episode!.finishedAtMs != null ||
          originalEpisode?.finishedAtMs != null;
      facts.add(_Facts(
          e,
          file.lengthSync(),
          played,
          id == playingId ||
              queued.contains(id) ||
              (listening.contains(id) && !played)));
    }
    if (forgot) _save();
    _facts = facts;
  }

  /// Removes audio until what is left fits the limit. True when a new
  /// episode may start: false only when what is left cannot be removed.
  Future<bool> makeRoom({int? playingId}) async {
    await refreshFacts(playingId: playingId);
    final remove = audioToRemove([
      for (final f in _facts)
        (
          spokenId: f.entry.spokenId!,
          bytes: f.bytes,
          madeAtMs: f.entry.madeAtMs ?? 0,
          played: f.played,
          immune: f.immune,
        ),
    ], _limitBytes);
    for (final id in remove) {
      final episode = await db.feedsDao.episodeOf(id);
      final url = episode?.enclosureUrl;
      if (url != null) {
        final file = audioFileFor(id, url);
        if (file.existsSync()) file.deleteSync();
      }
    }
    if (remove.isNotEmpty) await refreshFacts(playingId: playingId);
    return madeBytes < _limitBytes;
  }

  String _count(int n) => n == 1 ? '1 episode' : '$n episodes';

  /// The plain line for the Jobs page, or with [feedId] for one show.
  /// Null when there is nothing to say.
  String? line({int? feedId}) {
    final made =
        _facts.where((f) => feedId == null || f.entry.feedId == feedId).toList();
    final waits = waiting.where((e) => feedId == null || e.feedId == feedId).length;
    if (made.isEmpty && waits == 0) return null;
    final bytes = made.fold(0, (sum, f) => sum + f.bytes);
    return [
      if (made.isNotEmpty)
        'Made ahead: ${_count(made.length)}, ${formatBytes(bytes)}'
            '${feedId == null ? ' of ${formatBytes(_limitBytes)}' : ''}.',
      if (waits > 0)
        '${_count(waits)} waiting for Wi-Fi, charging and Trellis open.',
    ].join(' ');
  }

  /// How many bytes the made-ahead audio takes now.
  int get madeBytes => _facts.fold(0, (sum, f) => sum + f.bytes);
}

/// Wi-Fi and charging from the device's two meters. Either unknown counts
/// as no: a phone is not worked hard on a guess.
Future<bool> wifiAndCharging(
    Future<bool> Function() isMetered, Future<bool> Function() isCharging) async {
  try {
    return !await isMetered() && await isCharging();
  } catch (_) {
    return false;
  }
}
