import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/episodes/episode_actions.dart';
import 'package:trellis/features/listen/spoken_episode.dart';
import 'package:trellis/features/listen/spoken_share.dart';
import 'package:trellis/features/reader/speech/speech_engine.dart';
import 'package:trellis/services/device_services.dart';

import '../../support/fake_services.dart';

typedef _Sent = ({String name, String mimeType, String subject, String? text,
    Uint8List bytes});

/// Share on a made episode sends the audio itself (owner, 10 Nov: "I'd
/// like to make it so it produces an audio file that can be shared,
/// downloaded, cached"), named by its title and said to be a machine-made
/// voice. A file in a real host's cloned voice is a separate switch, off
/// by default (the owner's standing rule).
void main() {
  late Directory dir;
  late AppDatabase db;
  late int profileId;
  late int feedId;
  late DeviceServices services;
  late List<_Sent> files;
  late List<String> texts;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('trellis-spoken-share');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://cast.test/feed', title: 'Show');
    services = testServices(dir);
    files = [];
    texts = [];
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<Work> original() async {
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Harbour episode',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/1.mp3',
        lang: 'en');
    await db.feedsDao.insertEpisode(
        workId: id,
        feedId: feedId,
        guid: 'g1',
        enclosureUrl: 'https://cast.test/1.mp3',
        publishedAtMs: 5000);
    return (await db.spineDao.workById(id))!;
  }

  Future<int> made(Work of, {VoiceKind kind = VoiceKind.machine}) async {
    final wav = File('${dir.path}/render.wav');
    final render = await renderSpoken(
        sentences: const [(seg: 0, text: 'Hola a todos.')],
        synth: (t) async =>
            SynthResult(samples: Float32List(500), sampleRate: 1000),
        wav: wav);
    return storeSpokenEpisode(
        db: db,
        original: of,
        lang: 'es',
        voice: 'Pocket TTS',
        voiceKind: kind,
        render: render,
        audio: wav,
        audioFileFor: services.audioFileFor);
  }

  EpisodeActions actions() => EpisodeActions(
        db: db,
        profileId: profileId,
        services: services,
        localMlAvailable: true,
        shareText: (t, {subject}) async => texts.add(t),
        shareFile: (path, {required mimeType, required subject, text}) async =>
            files.add((
              name: path.split('/').last,
              mimeType: mimeType,
              subject: subject,
              text: text,
              bytes: File(path).readAsBytesSync(),
            )),
      );

  /// Real file work runs outside the test clock, so it is given real
  /// time between frames.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
    }
  }

  Future<void> tapShare(WidgetTester tester, int workId) async {
    final work = (await db.spineDao.workById(workId))!;
    final episode = await db.feedsDao.episodeOf(workId);
    final a = actions();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () => a.handleShared(
                        context, 'share', (work: work, episode: episode)),
                    child: const Text('go'))))));
    await tester.tap(find.text('go'));
    await settle(tester);
  }

  testWidgets(
      'a made episode shares its own audio file, named by its title, and '
      'says the voice is machine made', (tester) async {
    late int id;
    await tester.runAsync(() async => id = await made(await original()));
    await tapShare(tester, id);

    expect(texts, isEmpty, reason: 'the file goes, not only words');
    final sent = files.single;
    expect(sent.name, 'Harbour episode (Spanish).wav');
    expect(sent.mimeType, 'audio/wav');
    expect(sent.subject, 'Harbour episode (Spanish)');
    expect(sent.text, contains('machine-made voice'));
    final ep = (await db.feedsDao.episodeOf(id))!;
    expect(sent.bytes,
        services.audioFileFor(id, ep.enclosureUrl!).readAsBytesSync());
    expect(sent.text, isNot(contains('.invalid')));
  });

  testWidgets(
      'a file in a host’s cloned voice is never shared while the switch is '
      'off; words go instead. With the switch on, the file goes',
      (tester) async {
    late int id;
    await tester.runAsync(() async =>
        id = await made(await original(), kind: VoiceKind.cloned));
    expect((await db.feedsDao.episodeOf(id))!.voiceKind, 'cloned',
        reason: 'the kind is stored, not read back out of words');

    await tapShare(tester, id);
    expect(files, isEmpty);
    expect(texts.single, contains('Harbour episode (Spanish)'));
    expect(texts.single, contains('real person’s voice'));

    await db.deviceSettingsDao.write(shareClonedVoiceAudioKey, '1');
    await tapShare(tester, id);
    expect(files.single.name, 'Harbour episode (Spanish).wav');
    expect(files.single.text, contains('real person’s voice'));
  });

  testWidgets(
      'a made episode whose audio was deleted shares words and the '
      'original’s address, never its own unreachable one', (tester) async {
    late int id;
    await tester.runAsync(() async => id = await made(await original()));
    final ep = (await db.feedsDao.episodeOf(id))!;
    services.audioFileFor(id, ep.enclosureUrl!).deleteSync();

    await tapShare(tester, id);
    expect(files, isEmpty);
    expect(texts.single, contains('machine-made voice'));
    expect(texts.single, contains('https://cast.test/1.mp3'));
    expect(texts.single, isNot(contains('.invalid')));
  });

  testWidgets(
      'an episode with its audio on the phone offers the link or the file',
      (tester) async {
    final work = await original();
    final audio = services.audioFileFor(work.id, 'https://cast.test/1.mp3');
    audio.parent.createSync(recursive: true);
    audio.writeAsBytesSync([1, 2, 3]);

    await tapShare(tester, work.id);
    expect(find.text('Send the link'), findsOneWidget);
    expect(find.text('Send the audio file'), findsOneWidget);
    // Each choice is a full-size target.
    expect(tester.getSize(find.byKey(const Key('share-audio-file'))).height,
        greaterThanOrEqualTo(48));
    await tester.tap(find.text('Send the audio file'));
    await settle(tester);

    expect(texts, isEmpty);
    expect(files.single.name, 'Harbour episode.mp3');
    expect(files.single.mimeType, 'audio/mpeg');
    expect(files.single.bytes, [1, 2, 3]);
  });

  testWidgets('an episode with no audio on the phone shares its link at once',
      (tester) async {
    final work = await original();
    await tapShare(tester, work.id);
    expect(find.text('Send the audio file'), findsNothing);
    expect(files, isEmpty);
    expect(texts.single, contains('https://cast.test/1.mp3'));
  });
}
