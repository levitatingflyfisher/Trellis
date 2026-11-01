import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jobs_core/jobs_core.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/listen/listen_chain.dart';
import 'package:trellis/features/listen/listen_clearness.dart';
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
  late List<SpeechPace> paces;

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

  Future<void> writeTranslation([String lang = 'es']) async {
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
          lang: lang,
          sourceText: src,
          body: body);
    }
  }

  ListenChain chain({
    RecordingForegroundGate? gate,
    Future<void>? transcribeUntil,
    void Function(int workId)? stopTranscribing,
    void Function(int workId)? stopTranslating,
    Future<void>? translateUntil,
    String voiceName = 'Test voice',
    VoiceKind voiceKind = VoiceKind.machine,
    Future<File?> Function(File wav,
            {required String title, required String comment})?
        encode,
  }) =>
      ListenChain(
        encode: encode,
        db: db,
        foreground: gate,
        stopTranscribing: stopTranscribing,
        stopTranslating: stopTranslating,
        transcribe: (w, e) async {
          ran.add('transcribe');
          if (transcribeUntil != null) {
            await transcribeUntil;
            return;
          }
          if (transcribeWorks) await writeTranscript();
        },
        translate: (w, source, target, progress) async {
          ran.add('translate $source>$target');
          if (translateFails != null) return translateFails;
          if (translateUntil != null) {
            progress(1, 3);
            await translateUntil;
          }
          await writeTranslation(target);
          progress(3, 3);
          return null;
        },
        voiceFor: (_, lang) async => hasVoice
            ? (name: voiceName, voiceKind: voiceKind,
                say: (String t, SpeechPace pace) {
                ran.add('say $t');
                paces.add(pace);
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
    paces = [];
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

  test('the step chosen for how clearly the voice speaks is how every '
      'sentence is said, the pause written after it, and what the episode '
      'stores and says', () async {
    await writeListenClearness(db, ListenClearness.slow);

    final id = await chain().start(work, 'es');

    expect(paces, List.filled(3, ListenClearness.slow.pace));
    final ep = (await db.feedsDao.episodeOf(id!))!;
    expect(ep.clearness, 'slow');
    // A tenth of a second of sound a character: 'Hola.' 500 ms, then the
    // slow step's 800 ms pause, '¿Cómo estás?' 1200 ms, then its 1200 ms
    // pause after a paragraph, then 'Adiós.'.
    final rows = await db.spineDao.alignmentsOf(id);
    expect(rows.first.tStartMs, 0);
    expect(rows.last.tStartMs, 500 + 800 + 1200 + 1200,
        reason: 'the slow step’s pauses are in the stored times');
    final about = (await db.feedsDao.notesOf(id))!.plain;
    expect(about,
        contains('spoken slowly and clearly by a machine-made voice (Test '
            'voice)'));
  });

  test('made at another step: the tap makes it again in place at the step '
      'chosen now; at the same step nothing runs again', () async {
    final first = await chain().start(work, 'es');
    expect((await db.feedsDao.episodeOf(first!))!.clearness, 'natural');
    ran.clear();

    await writeListenClearness(db, ListenClearness.verySlow);
    final again = await chain().start(work, 'es');

    expect(again, first, reason: 'replaced in place, not a second copy');
    expect(ran, ['say Hola.', 'say ¿Cómo estás?', 'say Adiós.']);
    expect((await db.feedsDao.episodeOf(first))!.clearness, 'verySlow');

    ran.clear();
    expect(await chain().start(work, 'es'), first);
    expect(ran, isEmpty);
  });

  test('an episode made before the step was stored counts as Natural',
      () async {
    final first = await chain().start(work, 'es');
    await (db.update(db.episodes)..where((e) => e.workId.equals(first!)))
        .write(const EpisodesCompanion(clearness: Value(null)));
    ran.clear();

    expect(await chain().start(work, 'es'), first);
    expect(ran, isEmpty);
  });

  test('a stage whose result is already there is skipped', () async {
    await writeTranscript();
    await writeTranslation();

    await chain().start(work, 'es');

    expect(ran, ['say Hola.', 'say ¿Cómo estás?', 'say Adiós.']);
  });

  test('any language the voice can save is made the same way: French, '
      'named as French', () async {
    final id = await chain().start(work, 'fr');

    expect(ran.take(2), ['transcribe', 'translate en>fr']);
    expect(await spokenEpisodeOf(db, work.id, 'fr'), id);
    expect((await db.spineDao.workById(id!))!.title,
        'Harbour episode (French)');
  });

  test('an episode with no language of its own is translated from its '
      'show’s language, not taken for English', () async {
    await db.update(db.works).write(const WorksCompanion(lang: Value(null)));
    await db.update(db.feeds)
        .write(const FeedsCompanion(language: Value('fr-FR')));
    work = (await db.spineDao.workById(work.id))!;

    await chain().start(work, 'es');

    expect(ran, contains('translate fr>es'));
  });

  test('an episode nobody knows the language of is taken for English',
      () async {
    await db.update(db.works).write(const WorksCompanion(lang: Value(null)));
    work = (await db.spineDao.workById(work.id))!;

    await chain().start(work, 'es');

    expect(ran, contains('translate en>es'));
  });

  test('no transcript came of it: it stops and says so', () async {
    transcribeWorks = false;
    final c = chain();

    expect(await c.start(work, 'es'), isNull);

    expect(c.stateOf(work.id)!.stage, ListenStage.failed);
    expect(c.stateOf(work.id)!.message, contains('transcript'));
    expect(ran, ['transcribe']);
  });

  test('part of a transcript, still being made, is not translated: the '
      'transcription is carried on, and a pause there stops it', () async {
    // A transcription shown as it is made, paused after its first windows.
    await writeTranscript();
    await db.jobsDao.save(Job(
        id: 'transcribe-${work.id}',
        kind: 'transcribe',
        state: JobState.cancelled,
        checkpoint: null,
        totalUnits: 9,
        doneUnits: 2,
        createdAtMs: 5));
    await db.jobsDao.setPayload(
        'transcribe-${work.id}', '{"workId": ${work.id}, "soFar": true}');
    transcribeWorks = false;
    final c = chain();

    expect(await c.start(work, 'es'), isNull);

    expect(ran, ['transcribe']);
    expect(c.stateOf(work.id)!.stage, ListenStage.failed);
    expect(c.stateOf(work.id)!.message, contains('transcript'));
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

  // Seen on the emulator: Stop while transcribing changed nothing on the
  // row for minutes, because the chain only looked at its flag once the
  // whole transcript was done.
  test('cancel while transcribing stops the transcription too', () async {
    final done = Completer<void>();
    final stopped = <int>[];
    final c = chain(
      transcribeUntil: done.future,
      stopTranscribing: (id) {
        stopped.add(id);
        done.complete();
      },
    );

    final run = c.start(work, 'es');
    await pumpEventQueue();
    expect(c.stateOf(work.id)?.stage, ListenStage.transcribing);

    c.cancel(work.id);

    expect(stopped, [work.id]);
    expect(await run, isNull);
    expect(c.stateOf(work.id), isNull);
  });

  test('cancel while translating stops the translation too', () async {
    await writeTranscript();
    final stopped = <int>[];
    final until = Completer<void>();
    final c = chain(stopTranslating: stopped.add, translateUntil: until.future);
    final run = c.start(work, 'es');
    await pumpEventQueue();
    expect(c.stateOf(work.id)?.stage, ListenStage.translating);

    c.cancel(work.id);
    expect(stopped, [work.id]);

    until.complete();
    expect(await run, isNull);
  });

  test('cancel after the transcript does not touch transcription', () async {
    final stopped = <int>[];
    final c = chain(stopTranscribing: stopped.add);
    c.addListener(() {
      if (c.stateOf(work.id)?.stage == ListenStage.speaking) c.cancel(work.id);
    });

    expect(await c.start(work, 'es'), isNull);

    expect(stopped, isEmpty);
  });

  test('the phone’s own voice is named plainly on the episode’s page and '
      'in its file’s tag', () async {
    final tags = <(String, String)>[];
    final c = chain(
        voiceName: 'the phone’s own voice, Speech Services by Google',
        encode: (wav, {required title, required comment}) async {
          tags.add((title, comment));
          return null;
        });

    final id = await c.start(work, 'ru');

    expect(tags.single.$1, 'Harbour episode (Russian)');
    expect(
        tags.single.$2,
        contains('Machine-made voice (the phone’s own voice, Speech '
            'Services by Google)'));
    final about = (await db.feedsDao.notesOf(id!))!.plain;
    expect(about, contains('machine-made voice (the phone’s own voice, '
        'Speech Services by Google)'));
  });

  test('with no encoder, the WAV itself carries the title and the '
      'machine-made label, and the episode stores its voice kind', () async {
    final id = await chain().start(work, 'es');

    final ep = (await db.feedsDao.episodeOf(id!))!;
    expect(ep.voiceKind, 'machine');
    final file = testServices(dir).audioFileFor(id, ep.enclosureUrl!);
    final text = String.fromCharCodes(file.readAsBytesSync());
    expect(text, contains('INAM'));
    expect(text, contains('Harbour episode (Spanish)'));
    expect(text, contains('ICMT'));
    expect(text, contains('Machine-made voice (Test voice)'));
    // Still a whole RIFF file: its size field counts every byte after it.
    final bytes = file.readAsBytesSync();
    expect(ByteData.sublistView(bytes).getUint32(4, Endian.little),
        bytes.length - 8);
  });

  test('a cloned voice is stored as one, and its tag says whose voice it '
      'copies', () async {
    final tags = <String>[];
    final id = await chain(
        voiceKind: VoiceKind.cloned,
        encode: (wav, {required title, required comment}) async {
          tags.add(comment);
          return null;
        }).start(work, 'es');

    expect((await db.feedsDao.episodeOf(id!))!.voiceKind, 'cloned');
    expect(tags.single, contains('real person’s voice'));
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
