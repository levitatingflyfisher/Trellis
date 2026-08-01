// Campaign 7 ("audiobooks are a door", ADR-0013): the import repository's
// own laws — ordering, dedup, and missing-file tolerance ("a moved folder
// yields calm sentences, not crashes") — proven with an injected fake
// filesystem, never a real one.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/intake/audiobook_import.dart';

void main() {
  late AppDatabase db;
  late int profileId;
  final destinations = <String>[]; // src->dest calls, in order
  final missing = <String>{};

  AudiobookImportRepository repoFor({Set<String>? unreadable}) {
    destinations.clear();
    return AudiobookImportRepository(
      db: db,
      destinationFor: (workId, fileIdx, name) {
        final dot = name.lastIndexOf('.');
        final ext = dot < 0 ? '' : name.substring(dot);
        return File('/fake/audiobooks/$workId/$fileIdx$ext');
      },
      readable: (path) => !(unreadable ?? missing).contains(path),
      copyFile: (src, dest) => destinations.add('$src -> $dest'),
    );
  }

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    missing.clear();
  });

  tearDown(() => db.close());

  test('orders picked files naturally and persists the resulting fileIdx '
      'order, not pick order', () async {
    final picked = [
      (path: '/src/track10.mp3', name: 'track10.mp3'),
      (path: '/src/track2.mp3', name: 'track2.mp3'),
      (path: '/src/track1.mp3', name: 'track1.mp3'),
    ];
    final outcome = await repoFor().import(
      profileId: profileId,
      picked: picked,
      title: 'My Book',
    );
    expect(outcome, isNotNull);
    expect(outcome!.fileCount, 3);
    final files = await db.audiobooksDao.filesOf(outcome.workId);
    expect(files.map((f) => f.fileIdx), [0, 1, 2]);
    expect(
      destinations,
      [
        '/src/track1.mp3 -> /fake/audiobooks/${outcome.workId}/0.mp3',
        '/src/track2.mp3 -> /fake/audiobooks/${outcome.workId}/1.mp3',
        '/src/track10.mp3 -> /fake/audiobooks/${outcome.workId}/2.mp3',
      ],
    );
  });

  test('creates the work as kind=audiobook, persistence=work (never swept '
      'as ephemera) with the given title', () async {
    final outcome = await repoFor().import(
      profileId: profileId,
      picked: const [(path: '/src/a.mp3', name: 'a.mp3')],
      title: 'A Title',
    );
    final work = await db.spineDao.workById(outcome!.workId);
    expect(work!.kind, 'audiobook');
    expect(work.persistence, 'work');
    expect(work.title, 'A Title');
  });

  test('creates the per-book Audiobooks settings row', () async {
    final outcome = await repoFor().import(
      profileId: profileId,
      picked: const [(path: '/src/a.mp3', name: 'a.mp3')],
      title: 'A Title',
    );
    final settings = await db.audiobooksDao.audiobookOf(outcome!.workId);
    expect(settings, isNotNull);
    expect(settings!.speedOverride, isNull);
  });

  test('dedups a source path picked twice, keeping one file', () async {
    final picked = [
      (path: '/src/a.mp3', name: 'a.mp3'),
      (path: '/src/a.mp3', name: 'a.mp3'),
      (path: '/src/b.mp3', name: 'b.mp3'),
    ];
    final outcome = await repoFor().import(
      profileId: profileId,
      picked: picked,
      title: 'Title',
    );
    expect(outcome!.fileCount, 2);
  });

  test('a file that vanished between picking and confirming is skipped, '
      'not a crash — the rest of the book still imports', () async {
    missing.add('/src/gone.mp3');
    final picked = [
      (path: '/src/a.mp3', name: 'a.mp3'),
      (path: '/src/gone.mp3', name: 'gone.mp3'),
      (path: '/src/b.mp3', name: 'b.mp3'),
    ];
    final outcome = await repoFor().import(
      profileId: profileId,
      picked: picked,
      title: 'Title',
    );
    expect(outcome!.fileCount, 2);
    expect(outcome.skippedNames, ['gone.mp3']);
  });

  test('every file vanished: returns null, creates nothing', () async {
    missing.addAll({'/src/a.mp3', '/src/b.mp3'});
    final picked = [
      (path: '/src/a.mp3', name: 'a.mp3'),
      (path: '/src/b.mp3', name: 'b.mp3'),
    ];
    final before = await db.spineDao.worksOf(profileId);
    final outcome = await repoFor().import(
      profileId: profileId,
      picked: picked,
      title: 'Title',
    );
    expect(outcome, isNull);
    expect(await db.spineDao.worksOf(profileId), before);
  });
}
