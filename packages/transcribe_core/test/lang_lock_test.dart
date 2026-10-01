import 'dart:convert';

import 'package:jobs_core/jobs_core.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:test/test.dart';
import 'package:transcribe_core/transcribe_core.dart';

import 'helpers/fakes.dart';

/// 60s under the 30s/5s recipe: windows at 0, 25000 and 50000ms.
Map<int, List<TranscriptChunk>> speech(
        {String first = 'Privet, druzya, rad vas videt.'}) =>
    {
      0: [TranscriptChunk(text: first, tStartMs: 0, tEndMs: 2000)],
      25000: [
        TranscriptChunk(
            text: 'Kak dela u vas segodnya?', tStartMs: 0, tEndMs: 2000)
      ],
      50000: [
        TranscriptChunk(
            text: 'Poka, do novyh vstrech.', tStartMs: 0, tEndMs: 2000)
      ],
    };

TranscribeEpisodeTask makeTask(Transcriber t, {String? lang}) =>
    TranscribeEpisodeTask(
        source: ScriptedPcmSource(totalMs: 60000),
        transcriber: t,
        lang: lang,
        minSegmentChars: 1);

Future<Job> drive(TranscribeEpisodeTask task, {JobStore? store}) => JobRunner(
        store: store ?? InMemoryJobStore(),
        now: FakeClock().now,
        sleep: SleepRecorder().call)
    .run(jobId: 'ep', kind: 'transcribe', task: task);

void main() {
  group('whisperLanguageOf', () {
    test('takes the primary subtag of a feed language', () {
      expect(whisperLanguageOf('en-us'), 'en');
      expect(whisperLanguageOf('ru-RU'), 'ru');
      expect(whisperLanguageOf('es'), 'es');
      expect(whisperLanguageOf(' EN_gb '), 'en');
      expect(whisperLanguageOf('zh-Hant-TW'), 'zh');
    });

    test('keeps whisper\'s three-letter codes', () {
      expect(whisperLanguageOf('haw'), 'haw');
      expect(whisperLanguageOf('yue'), 'yue');
    });

    test('maps the legacy codes old feeds still carry', () {
      expect(whisperLanguageOf('iw'), 'he');
      expect(whisperLanguageOf('in'), 'id');
      expect(whisperLanguageOf('ji'), 'yi');
    });

    test('Cantonese tags map to whisper\'s yue, not Mandarin', () {
      for (final t in ['zh-yue', 'zh-HK', 'zh_mo', 'yue', 'yue-Hant-HK']) {
        expect(whisperLanguageOf(t), 'yue', reason: t);
      }
      expect(whisperLanguageOf('zh-TW'), 'zh');
    });

    test('codes feeds use for languages whisper files under another', () {
      expect(whisperLanguageOf('nb'), 'no');
      expect(whisperLanguageOf('nb-NO'), 'no');
      expect(whisperLanguageOf('nn'), 'no');
      expect(whisperLanguageOf('nn-NO'), 'no');
      expect(whisperLanguageOf('jv'), 'jw');
      expect(whisperLanguageOf('fil'), 'tl');
      expect(whisperLanguageOf('fil-PH'), 'tl');
      expect(whisperLanguageOf('mo'), 'ro');
    });

    test('whisper\'s own English language names are accepted', () {
      expect(whisperLanguageOf('English'), 'en');
      expect(whisperLanguageOf(' german '), 'de');
      expect(whisperLanguageOf('HAITIAN CREOLE'), 'ht');
      expect(whisperLanguageOf('Cantonese'), 'yue');
      expect(whisperLanguageOf('Javanese'), 'jw');
      expect(whisperLanguageOf('klingon'), isNull);
    });

    test('anything whisper does not know means auto', () {
      expect(whisperLanguageOf(null), isNull);
      expect(whisperLanguageOf(''), isNull);
      expect(whisperLanguageOf('xx-YY'), isNull);
      expect(whisperLanguageOf('auto'), isNull);
      expect(whisperLanguageOf('und'), isNull);
    });
  });

  group('language lock', () {
    test('a given language goes to every window', () async {
      final t = DetectingTranscriber(speech(), {0: 'de'});
      final task = makeTask(t, lang: 'ru');
      await drive(task);
      expect(t.seen.map((w) => w.lang), ['ru', 'ru', 'ru']);
      expect(task.langSource, LangSource.hint);
      expect(task.effectiveLang, 'ru');
    });

    test('without one, the first window detects and the rest are locked',
        () async {
      final t = DetectingTranscriber(speech(), {0: 'ru', 25000: 'en'});
      final task = makeTask(t);
      final job = await drive(task);
      expect(job.state, JobState.done);
      expect(t.seen.map((w) => w.lang), [null, 'ru', 'ru']);
      expect(task.langSource, LangSource.detected);
      expect(task.buildResult().lang, 'und',
          reason: 'a detection only steers decoding; it never becomes the '
              'work\'s language, where a wrong one would outlive the run');
    });

    test('a window with no words (an intro jingle) does not lock', () async {
      final t = DetectingTranscriber(
          speech(first: '[Music]'), {0: 'nn', 25000: 'ru'});
      final task = makeTask(t);
      await drive(task);
      expect(t.seen.map((w) => w.lang), [null, null, 'ru']);
    });

    test('a few words of hallucinated silence do not lock', () async {
      // Whisper invents "Thank you." on near-silence and reports whatever
      // language that came out as.
      final t = DetectingTranscriber(
          speech(first: 'Thank you.'), {0: 'en', 25000: 'ru'});
      final task = makeTask(t);
      await drive(task);
      expect(t.seen.map((w) => w.lang), [null, null, 'ru']);
    });

    test('marker text does not count toward the four words', () async {
      final t = DetectingTranscriber(
          speech(first: '[Music] (applause) one two three'),
          {0: 'en', 25000: 'ru'});
      await drive(makeTask(t));
      expect(t.seen.map((w) => w.lang), [null, null, 'ru']);
    });

    test('an engine that cannot report stays on auto', () async {
      final t = WindowScriptTranscriber(speech());
      final task = makeTask(t);
      await drive(task);
      expect(t.seen.map((w) => w.lang), [null, null, null]);
      expect(task.langSource, LangSource.auto);
      expect(task.buildResult().lang, 'und');
    });

    test('a detection whisper cannot be told back is not locked', () async {
      final t = DetectingTranscriber(speech(), {0: 'xx', 25000: 'ru'});
      await drive(makeTask(t));
      expect(t.seen.map((w) => w.lang), [null, null, 'ru']);
    });

    test('a resumed job keeps the language without detecting again', () async {
      final inner = InMemoryJobStore();
      final first = DetectingTranscriber(speech(), {0: 'ru'});
      await expectLater(
          drive(makeTask(first),
              store: KillingStore(inner, killOnCommit: 2, commitLands: true)),
          throwsA(isA<KilledProcess>()));
      expect(jsonDecode((await inner.load('ep'))!.checkpoint!)['lang'], 'ru');

      final second = DetectingTranscriber(speech(), {50000: 'de'});
      final task = makeTask(second);
      final job = await drive(task, store: inner);
      expect(job.state, JobState.done);
      expect(second.seen.map((w) => w.lang), ['ru']);
      expect(task.langSource, LangSource.detected);
    });

    test('a checkpoint from before the lock existed restores as auto', () {
      final task = makeTask(DetectingTranscriber(speech(), {}));
      task.restore(jsonEncode({'nextWindowStartMs': 25000, 'chunks': []}));
      expect(task.langSource, LangSource.auto);
    });
  });
}
