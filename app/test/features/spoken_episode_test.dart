import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/listen/spoken_episode.dart';
import 'package:trellis/features/reader/speech/speech_engine.dart';
import 'package:trellis/features/transcribe/transcript_writer.dart';

import '../support/fake_services.dart';

/// A real audio file for a translated episode (1.6.0, owner: "produces an
/// audio file that can be shared, downloaded, cached, and not have to run
/// the heavy engine every time"). The spoken translation is made once,
/// saved as one file with the time of every sentence, and stored as an
/// episode of its own beside the original, so the player, the queue and
/// the lit page all work on it as they do on any episode.
void main() {
  late Directory dir;
  late AppDatabase db;
  late int profileId;

  /// One second of sound per ten characters, at 1000 samples a second.
  Future<SynthResult> synth(String text) async => SynthResult(
      samples: Float32List(text.length * 100)..fillRange(0, 10, 0.5),
      sampleRate: 1000);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('trellis-spoken');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  group('rendering', () {
    test('every sentence is said once, in order, into one WAV file, and '
        'each knows when it starts and ends', () async {
      final wav = File('${dir.path}/out.wav');
      final said = <String>[];
      final render = await renderSpoken(
          sentences: const [
            (seg: 0, text: 'Hola a todos.'),
            (seg: 0, text: 'Buenos días.'),
            (seg: 1, text: 'Adiós.'),
          ],
          synth: (t) {
            said.add(t);
            return synth(t);
          },
          wav: wav);

      expect(said, ['Hola a todos.', 'Buenos días.', 'Adiós.']);
      expect(render.sampleRate, 1000);
      expect([for (final s in render.sentences) (s.seg, s.startMs, s.endMs)], [
        (0, 0, 1300),
        (0, 1300 + sentenceGapMs, 1300 + sentenceGapMs + 1200),
        (
          1,
          2500 + sentenceGapMs + segmentGapMs,
          2500 + sentenceGapMs + segmentGapMs + 600
        ),
      ]);
      expect(render.durationMs, render.sentences.last.endMs);
      // A well-formed 16-bit mono WAV of exactly that length.
      final bytes = wav.readAsBytesSync();
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
      final data = ByteData.sublistView(bytes);
      expect(data.getUint32(24, Endian.little), 1000);
      expect(data.getUint32(40, Endian.little), bytes.length - 44);
      expect(bytes.length - 44, render.durationMs * 2);
    });

    test('a sentence handed at another rate is brought to the file’s '
        'rate, so it lasts as long as it was said', () async {
      final wav = File('${dir.path}/out.wav');
      final render = await renderSpoken(
          sentences: const [
            (seg: 0, text: 'Hola a todos.'),
            (seg: 0, text: 'Adiós.'),
          ],
          synth: (t) async => t == 'Adiós.'
              // 600 ms of sound, at twice the rate.
              ? SynthResult(samples: Float32List(1200), sampleRate: 2000)
              : synth(t),
          wav: wav);

      expect(render.sampleRate, 1000);
      final last = render.sentences.last;
      expect(last.endMs - last.startMs, 600);
      expect(wav.lengthSync() - 44, render.durationMs * 2);
    });

    test('the pauses asked for are the silences written, and the times '
        'the page lights words by count them exactly', () async {
      final wav = File('${dir.path}/out.wav');
      final render = await renderSpoken(
          sentences: const [
            (seg: 0, text: 'Hola a todos.'),
            (seg: 0, text: 'Buenos días.'),
            (seg: 1, text: 'Adiós.'),
          ],
          synth: synth,
          wav: wav,
          sentenceGapMs: 1200,
          segmentGapMs: 1800);

      expect([for (final s in render.sentences) (s.startMs, s.endMs)], [
        (0, 1300),
        (2500, 3700),
        (5500, 6100),
      ]);
      expect(wav.lengthSync() - 44, 6100 * 2);
      // The silence is really there, between the two sounds.
      final data = ByteData.sublistView(wav.readAsBytesSync(), 44);
      for (final ms in [1300, 1800, 2499]) {
        expect(data.getInt16(ms * 2, Endian.little), 0, reason: '$ms ms');
      }
      expect(data.getInt16(2500 * 2, Endian.little), isNot(0));
    });

    test('progress is reported, and a cancel stops it and leaves no file',
        () async {
      final wav = File('${dir.path}/out.wav');
      final seen = <(int, int)>[];
      var stop = false;
      await expectLater(
          renderSpoken(
              sentences: const [
                (seg: 0, text: 'Uno.'),
                (seg: 0, text: 'Dos.'),
                (seg: 0, text: 'Tres.'),
              ],
              synth: synth,
              wav: wav,
              onProgress: (done, total) {
                seen.add((done, total));
                if (done == 2) stop = true;
              },
              cancelled: () => stop),
          throwsA(isA<SpokenCancelled>()));

      expect(seen, [(1, 3), (2, 3)]);
      expect(wav.existsSync(), isFalse);
    });

    test('a sentence the voice can’t say is skipped, not fatal', () async {
      final render = await renderSpoken(
          sentences: const [
            (seg: 0, text: 'Uno.'),
            (seg: 0, text: '???'),
            (seg: 0, text: 'Tres.'),
          ],
          synth: (t) => t == '???' ? throw StateError('no') : synth(t),
          wav: File('${dir.path}/out.wav'));

      expect([for (final s in render.sentences) s.text], ['Uno.', 'Tres.']);
    });
  });

  test('words inside a sentence share its time by their length', () {
    final rows = estimateWordTimings('Hola a todos.', 1000, 2300);
    expect([for (final r in rows) r[0]], ['Hola', 'a', 'todos.']);
    expect(rows.first[1], 1000);
    expect(rows.last[2], 2300);
    for (var i = 1; i < rows.length; i++) {
      expect(rows[i][1], rows[i - 1][2], reason: 'no gaps between words');
    }
    // "todos." is the longest word and gets the longest share.
    expect((rows[2][2] as int) - (rows[2][1] as int),
        greaterThan((rows[0][2] as int) - (rows[0][1] as int)));
  });

  test('Japanese words take one share each, as the page splits them', () {
    final rows = estimateWordTimings('今日はカレーです。', 0, 900);
    expect([for (final r in rows) r[0]], ['今', '日', 'は', 'カレー', 'で', 'す。']);
    expect(rows.first[1], 0);
    expect(rows.last[2], 900);
    for (var i = 1; i < rows.length; i++) {
      expect(rows[i][1], rows[i - 1][2], reason: 'no gaps between words');
    }
  });

  group('storing', () {
    late Work original;
    late int feedId;

    setUp(() async {
      feedId = await db.feedsDao.insertFeed(
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
      original = (await db.spineDao.workById(id))!;
    });

    Future<int> store(
        {List<({int seg, String text})> sentences = const [
          (seg: 0, text: 'Hola a todos.'),
          (seg: 0, text: 'Buenos días.'),
          (seg: 3, text: 'Adiós.'),
        ],
        String lang = 'es',
        String fileName = 'render.wav',
        bool kept = false}) async {
      final services = testServices(dir);
      final wav = File('${dir.path}/$fileName');
      final render =
          await renderSpoken(sentences: sentences, synth: synth, wav: wav);
      return storeSpokenEpisode(
          db: db,
          original: original,
          lang: lang,
          voice: 'Supertonic M1',
          render: render,
          audio: wav,
          kept: kept,
          audioFileFor: services.audioFileFor);
    }

    test('it is an episode of the same show, named for its language, with '
        'its audio where the player looks for a download', () async {
      final id = await store();

      final work = (await db.spineDao.workById(id))!;
      expect(work.kind, 'episode');
      expect(work.title, 'Harbour episode (Spanish)');
      expect(work.lang, 'es');
      final episode = (await db.feedsDao.episodeOf(id))!;
      expect(episode.feedId, feedId);
      expect(episode.guid, spokenGuid(original.id, 'es'));
      final file =
          testServices(dir).audioFileFor(id, episode.enclosureUrl!);
      expect(file.existsSync(), isTrue);
      expect(file.path, endsWith('.wav'));
      expect(await spokenEpisodeOf(db, original.id, 'es'), id);
      expect(await spokenEpisodeOf(db, original.id, 'ru'), isNull);
    });

    // Lead's ruling (12 Nov): the Library is what you keep, made episodes
    // among them; making one is as deliberate as Keep.
    test('a made episode asked for is kept, so it is in the Library, though '
        'its original was only passing through Latest', () async {
      final id = await store(kept: true);
      expect((await db.spineDao.workById(id))!.persistence, 'work');
      final library = await db.libraryDao.libraryQueryEntriesOf(profileId);
      expect([for (final e in library) e.work.id], [id]);
    });

    test('its text is the translation, a paragraph for each of the '
        'original’s, each with its time and its words’ times', () async {
      final id = await store();

      final segments = await db.spineDao.segmentsOf(id);
      expect([for (final s in segments) (s.idx, s.kind, s.body)], [
        (0, 'prose', 'Hola a todos. Buenos días.'),
        (1, 'prose', 'Adiós.'),
      ]);
      final alignments = await db.spineDao.alignmentsOf(id);
      expect([for (final a in alignments) (a.segmentIdx, a.tStartMs)],
          [(0, 0), (1, 2500 + sentenceGapMs + segmentGapMs)]);
      final words = decodeWordTimingBlob(alignments.first.wordTimings!);
      expect([for (final w in words) w[0]],
          ['Hola', 'a', 'todos.', 'Buenos', 'días.']);
    });

    test('Japanese sentences join with no space after each 。', () async {
      final id = await store(lang: 'ja', sentences: const [
        (seg: 0, text: '今日は晴れです。'),
        (seg: 0, text: '明日は雨です。'),
      ]);

      final segments = await db.spineDao.segmentsOf(id);
      expect([for (final s in segments) s.body], ['今日は晴れです。明日は雨です。']);
    });

    test('it says on its page that the voice is machine made, and which',
        () async {
      final id = await store();

      final notes = (await db.feedsDao.notesOf(id))!;
      expect(notes.plain, contains('machine-made voice'));
      expect(notes.plain, contains('Supertonic M1'));
      expect(notes.plain, contains('Harbour episode'));
    });

    Future<void> translatedBy(List<String> engines) async {
      for (final (i, engine) in engines.indexed) {
        await db.spineDao.upsertTranslationSentence(
            workId: original.id,
            segmentIdx: 0,
            sentenceIdx: i,
            lang: 'ja',
            sourceText: 'Sentence $i.',
            body: '文$i。',
            engine: engine);
      }
    }

    test('made from Japanese by the Anthropic brain, its page says so and '
        'never says the words were translated on this device', () async {
      await translatedBy(['domovoi:byokAnthropic', 'domovoi:byokAnthropic']);
      final id = await store(lang: 'ja', sentences: const [
        (seg: 0, text: '文0。'),
        (seg: 0, text: '文1。'),
      ]);

      final notes = (await db.feedsDao.notesOf(id))!.plain;
      expect(notes, contains('translated online by Anthropic’s Claude'));
      expect(notes, isNot(contains('translated on this device')));
    });

    test('made from both, its page names both', () async {
      await translatedBy(['domovoi:byokAnthropic', 'marian']);
      final id = await store(lang: 'ja', sentences: const [
        (seg: 0, text: '文0。'),
        (seg: 0, text: '文1。'),
      ]);

      final notes = (await db.feedsDao.notesOf(id))!.plain;
      expect(notes, contains('partly online by Anthropic’s Claude'));
      expect(notes, contains('partly on this device'));
    });

    test('made offline, its page says this device', () async {
      await translatedBy(['marian', 'marian']);
      final id = await store(lang: 'ja', sentences: const [
        (seg: 0, text: '文0。'),
        (seg: 0, text: '文1。'),
      ]);

      final notes = (await db.feedsDao.notesOf(id))!.plain;
      expect(notes, contains('translated on this device'));
      expect(notes, isNot(contains('Anthropic')));
    });

    test('making it again replaces the first, not adds a second', () async {
      final first = await store();
      final second = await store();

      expect(second, first);
      expect(
          (await db.spineDao.worksOf(profileId))
              .where((w) => w.title.endsWith('(Spanish)')),
          hasLength(1));
    });

    test('making it again as another file type leaves no old file behind',
        () async {
      final id = await store(fileName: 'first.ogg');
      final services = testServices(dir);
      final oldFile = services.audioFileFor(
          id, (await db.feedsDao.episodeOf(id))!.enclosureUrl!);
      expect(oldFile.path, endsWith('.ogg'));
      expect(oldFile.existsSync(), isTrue);

      final again = await store(fileName: 'second.m4a');

      expect(again, id);
      final newFile = services.audioFileFor(
          id, (await db.feedsDao.episodeOf(id))!.enclosureUrl!);
      expect(newFile.path, endsWith('.m4a'));
      expect(newFile.existsSync(), isTrue);
      expect(oldFile.existsSync(), isFalse);
    });
  });
}
