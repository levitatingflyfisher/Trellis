import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/karaoke_screen.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/reader/reader_screen.dart';
import 'package:trellis/features/reader/speech/speech_engine.dart';
import 'package:trellis/features/reader/speech/speech_temp_files.dart';
import 'package:trellis/features/reader/translation/marian_engine.dart';

import '../support/fake_player.dart';
import '../support/fake_tts.dart';

/// The study crown, Phase 3: read<->listen handoff verbs. Both directions'
/// math already exists (Spine.positionAtAudioTime / projectAudioTime,
/// proven at packages/loom_core/test/cursor_law_test.dart); this file is
/// the UI wiring — "Listen from here" in the reader, "Read from here" in
/// the karaoke (synced-text) view — over the SAME canonical Position row
/// the player and reader already both read and write (ADR-0002). Neither
/// verb invents a second position store.
void main() {
  late AppDatabase db;
  late FakeEpisodePlayer fakePlayer;
  late PlayerController controller;
  late int profileId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    fakePlayer = FakeEpisodePlayer();
    profileId = await db.profilesDao.create('Ada');
    controller = PlayerController(
        db: db, profileId: profileId, createPlayer: () => fakePlayer);
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
  });

  Future<Work> seedAlignedEpisode() async {
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Ep 1',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/1.mp3');
    await db.spineDao.insertSegments(workId, const [
      (idx: 0, kind: 'prose', text: 'First sentence.'),
      (idx: 1, kind: 'prose', text: 'Second sentence.'),
    ]);
    await db.spineDao.insertAlignments(workId, const [
      (segmentIdx: 0, tStartMs: 0, tEndMs: 10000),
      (segmentIdx: 1, tStartMs: 10000, tEndMs: 20000),
    ]);
    return (await db.spineDao.worksOf(profileId)).single;
  }

  group('"Listen from here" (reader -> player)', () {
    testWidgets(
        'hidden when there is no player wired in (never a dead button)',
        (tester) async {
      final work = await seedAlignedEpisode();
      await tester.pumpWidget(MaterialApp(
          home: ReaderScreen(db: db, profileId: profileId, work: work)));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('listen-from-here')), findsNothing);
    });

    testWidgets('hidden when the work has no aligned audio', (tester) async {
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'note',
          title: 'Plain note',
          persistence: 'work',
          firstSeenEpochDay: 100);
      await db.spineDao
          .insertSegments(workId, const [(idx: 0, kind: 'prose', text: 'Hi.')]);
      final work = (await db.spineDao.worksOf(profileId)).single;
      await tester.pumpWidget(MaterialApp(
          home: ReaderScreen(
              db: db, profileId: profileId, work: work, player: controller)));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('listen-from-here')), findsNothing);
    });

    testWidgets(
        'tapping it starts playback at the audio time the reading cursor '
        'projects to', (tester) async {
      final work = await seedAlignedEpisode();
      await tester.pumpWidget(MaterialApp(
          home: ReaderScreen(
              db: db, profileId: profileId, work: work, player: controller)));
      await tester.pumpAndSettle();

      // Move the cursor into segment 1 (scroll mode, tap the second
      // word). Campaign 9 Phase 6: `mode-toggle` opens a labeled
      // three-way picker rather than cycling on its own tap.
      await tester.tap(find.byKey(const Key('mode-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('mode-item-scroll')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Second'));
      await tester.pump();

      expect(find.byKey(const Key('listen-from-here')), findsOneWidget);
      await tester.tap(find.byKey(const Key('listen-from-here')));
      await tester.pumpAndSettle();

      expect(fakePlayer.loadedUrl, 'https://cast.test/1.mp3');
      expect(fakePlayer.log.last, 'seek:10000',
          reason: 'segment 1 (where the cursor landed) starts at 10000ms');
    });
  });

  group('"Read from here" (player -> reader)', () {
    testWidgets(
        'always offered in the karaoke view (alignments are guaranteed '
        'there — the promise is never dangled before it can be kept)',
        (tester) async {
      final work = await seedAlignedEpisode();
      await controller.playWork(work);
      await tester.pumpWidget(MaterialApp(
          home: KaraokeScreen(db: db, controller: controller, work: work)));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('read-from-here')), findsOneWidget);
    });

    testWidgets(
        'tapping it saves the current playback position through the SAME '
        'Position row, then opens the reader there', (tester) async {
      final work = await seedAlignedEpisode();
      await controller.playWork(work);
      fakePlayer.emitPosition(const Duration(seconds: 15)); // inside seg 1
      await tester.pumpWidget(MaterialApp(
          home: KaraokeScreen(db: db, controller: controller, work: work)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('read-from-here')));
      await tester.pumpAndSettle();

      final saved =
          await db.spineDao.position(profileId: profileId, workId: work.id);
      expect(saved!.segmentIdx, 1);
      expect(saved.lastModality, 'listen',
          reason: 'the write-through is the existing saveProgress path, '
              'unchanged — no second position store invented for this verb');
      // And the reader screen is now showing, having read that same row.
      expect(find.byType(ReaderScreen), findsOneWidget);
    });

    testWidgets(
        'threads tts/resolveSpeechEngine/createSpeechTempFiles/'
        'resolveTranslator through to the reader it opens — the same '
        'reachability library/river-opened readers already have '
        '(ADR-0008 Babel Phase 3)', (tester) async {
      final work = await seedAlignedEpisode();
      await controller.playWork(work);
      final tts = FakeTtsSpeaker();
      Future<SynthesisSpeechEngine?> resolveSpeechEngine({String? lang}) async =>
          null;
      SpeechTempFiles createSpeechTempFiles() =>
          DiskSpeechTempFiles(dir: Directory.systemTemp);
      Future<MarianTranslator?> resolveTranslator(
              {required String sourceLang, required String targetLang}) async =>
          null;
      Future<List<String>> availableTranslationTargets(
              {required String sourceLang}) async =>
          const [];

      await tester.pumpWidget(MaterialApp(
          home: KaraokeScreen(
              db: db,
              controller: controller,
              work: work,
              tts: tts,
              resolveSpeechEngine: resolveSpeechEngine,
              createSpeechTempFiles: createSpeechTempFiles,
              resolveTranslator: resolveTranslator,
              availableTranslationTargets: availableTranslationTargets)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('read-from-here')));
      await tester.pumpAndSettle();

      final reader = tester.widget<ReaderScreen>(find.byType(ReaderScreen));
      expect(reader.tts, same(tts));
      expect(reader.resolveSpeechEngine, same(resolveSpeechEngine));
      expect(reader.createSpeechTempFiles, same(createSpeechTempFiles));
      expect(reader.resolveTranslator, same(resolveTranslator));
      expect(reader.availableTranslationTargets,
          same(availableTranslationTargets));
    });
  });
}
