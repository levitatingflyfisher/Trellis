import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/listen/listen_chain.dart';
import 'package:trellis/features/listen/spoken_episode.dart';
import 'package:trellis/features/reader/speech/speech_engine.dart';

import '../support/fake_services.dart';

/// One tap (1.6.0, owner: "I click play on it and then I listen to it in
/// my learning language"): transcribe, translate, speak and save run as
/// one job, each stage skipped when its result is already there.
void main() {
  late Directory dir;
  late AppDatabase db;
  late int profileId;
  late Work work;
  late List<String> ran;
  late bool transcribeWorks;
  late String? translateFails;
  late bool hasVoice;

  Future<SynthResult> synth(String text) async => SynthResult(
      samples: Float32List(text.length * 100), sampleRate: 1000);

  Future<void> writeTranscript() async {
    await db.spineDao.insertSegments(work.id, const [
      (idx: 0, kind: 'prose', text: 'Hello there. How are you?'),
      (idx: 1, kind: 'prose', text: 'Goodbye now.'),
    ]);
    await db.spineDao.insertAlignments(work.id, const [
      (segmentIdx: 0, tStartMs: 0, tEndMs: 4000),
      (segmentIdx: 1, tStartMs: 4000, tEndMs: 6000),
    ]);
  }

  Future<void> writeTranslation() async {
    const rows = [
      (0, 0, 'Hello there.', 'Hola.'),
      (0, 1, 'How are you?', '¿Cómo estás?'),
      (1, 0, 'Goodbye now.', 'Adiós.'),
    ];
    for (final (seg, i, src, body) in rows) {
      await db.spineDao.upsertTranslationSentence(
          workId: work.id,
          segmentIdx: seg,
          sentenceIdx: i,
          lang: 'es',
          sourceText: src,
          body: body);
    }
  }

  ListenChain chain({RecordingForegroundGate? gate}) => ListenChain(
        db: db,
        foreground: gate,
        transcribe: (w, e) async {
          ran.add('transcribe');
          if (transcribeWorks) await writeTranscript();
        },
        translate: (w, source, target, progress) async {
          ran.add('translate $source>$target');
          if (translateFails != null) return translateFails;
          await writeTranslation();
          progress(3, 3);
          return null;
        },
        voiceFor: (lang) async => hasVoice
            ? (name: 'Test voice', say: (String t) {
                ran.add('say $t');
                return synth(t);
              })
            : null,
        audioFileFor: testServices(dir).audioFileFor,
        tempDir: Directory('${dir.path}/tmp'),
      );

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('trellis-listen-chain');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    final feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://cast.test/feed', title: 'Show');
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
    work = (await db.spineDao.workById(id))!;
    ran = [];
    transcribeWorks = true;
    translateFails = null;
    hasVoice = true;
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  test('from nothing: it transcribes, translates, speaks every sentence '
      'and saves the episode, saying where it is as it goes', () async {
    final c = chain();
    final stages = <ListenStage>[];
    c.addListener(() {
      final s = c.stateOf(work.id)?.stage;
      if (s != null && (stages.isEmpty || stages.last != s)) stages.add(s);
    });

    final id = await c.start(work, 'es');

    expect(ran, [
      'transcribe',
      'translate en>es',
      'say Hola.',
      'say ¿Cómo estás?',
      'say Adiós.',
    ]);
    expect(stages, [
      ListenStage.transcribing,
      ListenStage.translating,
      ListenStage.speaking,
      ListenStage.ready,
    ]);
    expect(id, isNotNull);
    expect(c.stateOf(work.id)!.spokenWorkId, id);
    expect(await spokenEpisodeOf(db, work.id, 'es'), id);
    expect((await db.spineDao.workById(id!))!.title,
        'Harbour episode (Spanish)');
    expect(Directory('${dir.path}/tmp').listSync(), isEmpty,
        reason: 'no working file is left behind');
  });

  test('already made: nothing runs again', () async {
    final first = await chain().start(work, 'es');
    ran.clear();

    final again = await chain().start(work, 'es');

    expect(again, first);
    expect(ran, isEmpty);
  });

  test('its audio was deleted since: the same tap makes it again, in '
      'place, from the translation that is still there', () async {
    final first = await chain().start(work, 'es');
    final episode = (await db.feedsDao.episodeOf(first!))!;
    final file = testServices(dir).audioFileFor(first, episode.enclosureUrl!);
    file.deleteSync();
    ran.clear();

    final again = await chain().start(work, 'es');

    expect(again, first);
    expect(ran, ['say Hola.', 'say ¿Cómo estás?', 'say Adiós.']);
    expect(file.existsSync(), isTrue);
  });

  test('a stage whose result is already there is skipped', () async {
    await writeTranscript();
    await writeTranslation();

    await chain().start(work, 'es');

    expect(ran, ['say Hola.', 'say ¿Cómo estás?', 'say Adiós.']);
  });

  test('no transcript came of it: it stops and says so', () async {
    transcribeWorks = false;
    final c = chain();

    expect(await c.start(work, 'es'), isNull);

    expect(c.stateOf(work.id)!.stage, ListenStage.failed);
    expect(c.stateOf(work.id)!.message, contains('transcript'));
    expect(ran, ['transcribe']);
  });

  test('the translator’s own sentence is what is shown when it fails',
      () async {
    translateFails = 'Trellis has no translator from English to Klingon.';
    final c = chain();

    expect(await c.start(work, 'es'), isNull);

    expect(c.stateOf(work.id)!.message, translateFails);
  });

  test('no voice that can be saved for the language: it says so, and the '
      'translation is kept', () async {
    hasVoice = false;
    final c = chain();

    expect(await c.start(work, 'es'), isNull);

    final state = c.stateOf(work.id)!;
    expect(state.stage, ListenStage.failed);
    expect(state.message, contains('Spanish'));
    expect(state.message, contains('voice'));
    expect(await db.spineDao.translationSentencesOf(work.id, lang: 'es'),
        hasLength(3));
    expect(await spokenEpisodeOf(db, work.id, 'es'), isNull);
  });

  test('the whole job holds the app awake behind a dark screen, from '
      'before the transcript to the end, with its progress', () async {
    final gate = RecordingForegroundGate();

    await chain(gate: gate).start(work, 'es');

    expect(gate.events.first, 'start:Harbour episode');
    // Taken before transcribing, not after: the transcription lets go
    // of its own hold when it ends.
    expect(ran.first, 'transcribe');
    expect(gate.events, contains('progress:Making the Spanish audio: 3 of 3 '
        'sentences'));
    expect(gate.events.last, 'finished');
    expect(gate.events.where((e) => e == 'finished'), hasLength(1));
  });

  test('it lets go when it fails, too', () async {
    translateFails = 'No.';
    final gate = RecordingForegroundGate();

    await chain(gate: gate).start(work, 'es');

    expect(gate.events.last, 'finished');
  });

  test('a second tap while it runs joins the first', () async {
    final c = chain();
    final a = c.start(work, 'es');
    final b = c.start(work, 'es');

    expect(await a, await b);
    expect(ran.where((r) => r == 'transcribe'), hasLength(1));
  });

  test('cancel stops it and leaves no episode', () async {
    final c = chain();
    c.addListener(() {
      if (c.stateOf(work.id)?.stage == ListenStage.speaking) c.cancel(work.id);
    });

    expect(await c.start(work, 'es'), isNull);

    expect(c.stateOf(work.id), isNull);
    expect(await spokenEpisodeOf(db, work.id, 'es'), isNull);
  });

  test('each stage has a plain line for the page', () {
    expect(
        const ListenState(ListenStage.translating, lang: 'es', done: 4, total: 9)
            .line,
        'Translating into Spanish: 4 of 9 sentences');
    expect(
        const ListenState(ListenStage.speaking, lang: 'es', done: 4, total: 9)
            .line,
        'Making the Spanish audio: 4 of 9 sentences');
    expect(const ListenState(ListenStage.transcribing, lang: 'es').line,
        'Transcribing the episode…');
  });
}
