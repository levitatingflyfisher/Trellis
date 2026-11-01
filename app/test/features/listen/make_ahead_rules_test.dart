import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/listen/make_ahead.dart';

/// The record and the rules of make ahead, with no engine: what counts as
/// new, how many, and what leaves the device first.
void main() {
  late AppDatabase db;
  late int profileId;
  late int feedId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://cast.test/feed', title: 'Show');
  });
  tearDown(() => db.close());

  var serial = 0;
  Future<int> episode(int publishedAtMs, {String? guid}) async {
    final n = ++serial;
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'E$n',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/$n.mp3',
        lang: 'en');
    await db.feedsDao.insertEpisode(
        workId: id,
        feedId: feedId,
        guid: guid ?? 'g$n',
        enclosureUrl: 'https://cast.test/$n.mp3',
        publishedAtMs: publishedAtMs);
    return id;
  }

  Future<List<int>> picks(
          {required int after, int room = 3, Set<int> skip = const {}}) async =>
      [
        for (final e in aheadPicks(await db.feedsDao.episodesOfFeed(feedId),
            afterWorkId: after, room: room, skip: skip.contains))
          e.workId,
      ];

  test('only what arrived after the mark, newest first, and no more than '
      'there is room for', () async {
    final old = await episode(1000);
    await episode(2000);
    final b = await episode(3000);
    final c = await episode(4000);
    final d = await episode(5000);
    expect(await picks(after: old), [d, c, b]);
    expect(await picks(after: old, room: 1), [d]);
    expect(await picks(after: d), isEmpty);
    expect(await picks(after: old, room: 0), isEmpty);
  });

  test('a spoken translation is the app’s own output, never something to '
      'translate', () async {
    final old = await episode(1000);
    final real = await episode(2000);
    await episode(2001, guid: 'spoken:$real:fr');
    expect(await picks(after: old), [real]);
  });

  test('one the rule skips is left out, and the next newest takes its '
      'place', () async {
    final old = await episode(1000);
    final a = await episode(2000);
    final b = await episode(3000);
    expect(await picks(after: old, room: 1, skip: {b}), [a]);
  });

  group('the room rule', () {
    AheadFile file(int id, int bytes, int madeAtMs,
            {bool played = false, bool immune = false}) =>
        (
          spokenId: id,
          bytes: bytes,
          madeAtMs: madeAtMs,
          played: played,
          immune: immune
        );

    test('under the limit nothing goes', () {
      expect(audioToRemove([file(1, 10, 1), file(2, 10, 2)], 20), isEmpty);
    });

    test('the oldest goes first, and only as many as it takes', () {
      expect(
          audioToRemove([file(3, 10, 3), file(1, 10, 1), file(2, 10, 2)], 20),
          [1]);
    });

    test('a played one goes before an unplayed one, even a newer one', () {
      expect(
          audioToRemove(
              [file(1, 10, 1), file(2, 10, 2, played: true), file(3, 10, 3)],
              20),
          [2]);
    });

    test('an immune one is never removed, though it takes room', () {
      expect(
          audioToRemove(
              [file(1, 10, 1, immune: true), file(2, 10, 2), file(3, 10, 3)],
              15),
          [2, 3]);
    });
  });

  test('the record comes back as written', () {
    final book = AheadBook(shows: {
      7: (after: 40, agreedLang: 'fr')
    }, entries: [
      const AheadEntry(workId: 41, feedId: 7, publishedAtMs: 900, tries: 1),
      const AheadEntry(workId: 42, feedId: 7, publishedAtMs: 901)
          .madeAs(99, 'fr', 5000),
    ]);
    final back = AheadBook.decode(book.encode())!;
    expect(back.shows[7], (after: 40, agreedLang: 'fr'));
    expect(back.entries.map((e) => e.toJson()),
        book.entries.map((e) => e.toJson()));
  });

  test('a restore forgets the record, as it forgets the other consents',
      () async {
    await db.deviceSettingsDao.write(makeAheadKey, AheadBook().encode());
    await db.feedsDao.clearAutoDownloadConsent();
    expect(await db.deviceSettingsDao.read(makeAheadKey), isNull);
  });

  test('a record of the wrong shape is set aside and the record starts '
      'empty', () async {
    await db.deviceSettingsDao.write(makeAheadKey, '{not json');
    final book = await readAheadBook(db);
    expect(book.shows, isEmpty);
    expect(await db.deviceSettingsDao.read(makeAheadKey), isNull);
    expect(await db.deviceSettingsDao.read('$makeAheadKey-unreadable'),
        '{not json');
  });
}
