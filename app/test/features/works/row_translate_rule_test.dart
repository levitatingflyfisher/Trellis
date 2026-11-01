import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/episodes/episode_actions.dart';
import 'package:trellis/features/works/work_menu.dart';
import 'package:trellis/features/works/work_row.dart';

import 'package:trellis/features/transcribe/transcribe_coordinator.dart';
import 'package:trellis/features/transcribe/transcript_so_far.dart';

import '../../support/fake_services.dart';

/// 1.5.8: a row's ⋮ offers Whisper's transcribe-and-translate-to-English
/// by the work page's rule — only once there is a transcript, and never
/// for an English work (its own language, else its show's).
void main() {
  test('the rule itself', () {
    expect(offersEnglishTranslate(wholeTranscript: false, sourceLang: 'es'),
        isFalse);
    expect(offersEnglishTranslate(wholeTranscript: true, sourceLang: 'en'),
        isFalse);
    expect(offersEnglishTranslate(wholeTranscript: true, sourceLang: 'en-US'),
        isFalse);
    expect(offersEnglishTranslate(wholeTranscript: true, sourceLang: 'es'),
        isTrue);
    expect(offersEnglishTranslate(wholeTranscript: true, sourceLang: null),
        isTrue);
  });

  group('row menus', () {
    late AppDatabase db;
    late int profileId;
    late EpisodeActions actions;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      profileId = await db.profilesDao.create('Ada');
      actions = EpisodeActions(
          db: db,
          profileId: profileId,
          transcriber: TranscribeCoordinator(
              db: db, services: testServices(Directory.systemTemp)),
          useDefaultShare: false);
    });
    tearDown(() => db.close());

    Future<WorkEntry> episode({String? feedLang}) async {
      final feedId = await db.feedsDao.insertFeed(
          profileId: profileId, url: 'https://x.test/f', title: 'Show');
      if (feedLang != null) {
        await db.customStatement(
            'UPDATE feeds SET language = ? WHERE id = ?', [feedLang, feedId]);
      }
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: 'Ep',
          persistence: 'work',
          firstSeenEpochDay: 100,
          sourceUrl: 'https://x.test/1.mp3');
      await db.feedsDao.insertEpisode(
          workId: workId,
          feedId: feedId,
          guid: 'g',
          enclosureUrl: 'https://x.test/1.mp3',
          publishedAtMs: 1);
      final work = await db.spineDao.workById(workId);
      final ep = await db.feedsDao.episodeOf(workId);
      return (work: work!, episode: ep);
    }

    Iterable<Object?> values(List<PopupMenuEntry<String>> items) =>
        items.whereType<PopupMenuItem<String>>().map((i) => i.value);

    test('an untranscribed episode has no translate', () async {
      final e = await episode(feedLang: 'es');
      final state = await WorkListState.load(db, profileId, entries: [e]);
      expect(
          values(workMenuItems(actions, e,
              transcript: TranscriptStage.none, sourceLang: state.sourceLangOf(e))),
          isNot(contains('translate')));
    });

    test('a transcribed English show has no translate', () async {
      final e = await episode(feedLang: 'en');
      final state = await WorkListState.load(db, profileId, entries: [e]);
      expect(
          values(workMenuItems(actions, e,
              transcript: TranscriptStage.whole, sourceLang: state.sourceLangOf(e))),
          isNot(contains('translate')));
    });

    test('a transcribed Spanish show keeps it', () async {
      final e = await episode(feedLang: 'es');
      final state = await WorkListState.load(db, profileId, entries: [e]);
      expect(
          values(workMenuItems(actions, e,
              transcript: TranscriptStage.whole, sourceLang: state.sourceLangOf(e))),
          contains('translate'));
    });
  });
}
