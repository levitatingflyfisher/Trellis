import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/episodes/episode_actions.dart';
import 'package:trellis/features/listen/listen_chain.dart';
import 'package:trellis/features/listen/spoken_episode.dart' show VoiceKind;
import 'package:trellis/features/listen/listen_jobs.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/player/queue_screen.dart';
import 'package:trellis/features/reader/speech/speech_engine.dart';
import 'package:trellis/features/transcribe/transcribe_coordinator.dart';

import '../../support/fake_player.dart';
import '../../support/fake_services.dart';

/// The second button reaches every list of episodes, and all of them ask
/// the same owner: a job started in Latest shows in the Queue.
void main() {
  late Directory dir;
  late AppDatabase db;
  late int profileId;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('trellis-listen-wiring');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  test('every screen’s actions share one owner of the one tap, so what is '
      'being made is the same answer in every list', () {
    final services = testServices(dir);
    final transcriber = TranscribeCoordinator(db: db, services: services);
    EpisodeActions actions(TranscribeCoordinator? t) => EpisodeActions(
        db: db, profileId: profileId, services: services, transcriber: t);

    final latest = actions(transcriber);
    final show = actions(transcriber);
    expect(latest.listenJobs, isNotNull);
    expect(identical(latest.listenJobs, show.listenJobs), isTrue);

    // Another device stack (another test, another profile's shell) has
    // its own.
    final other = actions(TranscribeCoordinator(db: db, services: services));
    expect(identical(latest.listenJobs, other.listenJobs), isFalse);

    // Where nothing can be transcribed there is no owner, and no button.
    expect(actions(null).listenJobs, isNull);
    expect(
        EpisodeActions(
                db: db,
                profileId: profileId,
                services: services,
                transcriber: transcriber,
                localMlAvailable: false)
            .listenJobs,
        isNull);
  });

  test('every list of episodes hands its rows the second button', () {
    for (final screen in [
      'lib/features/river/river_screen.dart',
      'lib/features/feeds/feed_detail_screen.dart',
      'lib/features/player/queue_screen.dart',
      'lib/features/library/library_screen.dart',
      // History and search results draw the same tile.
      'lib/features/search/search_screen.dart',
    ]) {
      final text = File(screen).readAsStringSync();
      expect(text, contains('.listenButton('), reason: screen);
      expect(RegExp(r'second:\s+\S*\.listenButton\(').hasMatch(text), isTrue,
          reason: '$screen: the button goes in the row’s second slot');
    }
  });

  testWidgets('the Queue’s row carries the button, and none for a row that '
      'has nothing to make', (tester) async {
    final feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://cast.test/feed', title: 'Show');
    Future<int> add(String title, {required bool audio}) async {
      final id = await db.spineDao.insertWork(
          profileId: profileId,
          kind: audio ? 'episode' : 'article',
          title: title,
          persistence: 'ephemeron',
          firstSeenEpochDay: 100,
          sourceUrl: 'https://cast.test/$title',
          lang: 'en');
      await db.feedsDao.insertEpisode(
          workId: id,
          feedId: feedId,
          guid: title,
          enclosureUrl: audio ? 'https://cast.test/$title.mp3' : null,
          publishedAtMs: 5000);
      await db.queueDao.playLast(profileId: profileId, workId: id, nowMs: 1);
      return id;
    }

    final harbour = await add('Harbour', audio: true);
    final notes = await add('Notes', audio: false);
    await db.deviceSettingsDao.write(learningLanguageKey, 'es');
    final player = PlayerController(
        db: db, profileId: profileId, createPlayer: FakeEpisodePlayer.new);
    addTearDown(player.dispose);
    final jobs = ListenJobs(
      db: db,
      chain: ListenChain(
        db: db,
        transcribe: (w, e) async {},
        translate: (w, s, t, p) async => null,
        voiceFor: (_, lang) async => (
          name: 'Test voice',
          voiceKind: VoiceKind.machine,
          say: (String t, SpeechPace p) async =>
              SynthResult(samples: Float32List(100), sampleRate: 1000),
        ),
        audioFileFor: testServices(dir).audioFileFor,
        tempDir: Directory('${dir.path}/tmp'),
      ),
      languagesFor: ({required workLang, required feedLang}) => const ['es'],
      downloadsFor: (w, e, lang) async => const [],
      player: player,
    );

    await tester.pumpWidget(MaterialApp(
        home: QueueScreen(
            db: db,
            profile: (await db.profilesDao.all()).single,
            player: player,
            actions: EpisodeActions(
                db: db,
                profileId: profileId,
                player: player,
                listenJobs: jobs))));
    await tester.pumpAndSettle();

    expect(find.byKey(Key('play-$harbour')), findsOneWidget);
    expect(find.byKey(Key('listen-$harbour')), findsOneWidget);
    expect(find.byTooltip('Listen in Spanish'), findsOneWidget);
    expect(find.byKey(Key('listen-$notes')), findsNothing);
  });
}
