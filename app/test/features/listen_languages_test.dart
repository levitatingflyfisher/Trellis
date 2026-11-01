import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/listen/listen_chain.dart';
import 'package:trellis/features/listen/listen_device.dart';
import 'package:trellis/features/reader/speech/phone_voice.dart';
import 'package:trellis/features/reader/translation/language_names.dart';
import 'package:trellis/features/transcribe/transcribe_coordinator.dart';

import '../support/fake_services.dart';

/// Which languages the one tap offers for an episode (owner: "any
/// language we have translation for will have the one click"): those the
/// downloaded voice can save AND a translator reaches from the episode's
/// own language, directly or by way of English. Where there is none, the
/// list is empty and the page shows no button.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('trellis-listen-l'));
  tearDown(() => dir.deleteSync(recursive: true));

  List<String> offered(String? workLang, {String? feedLang}) =>
      listenLanguagesFor(testServices(dir),
          workLang: workLang, feedLang: feedLang);

  test('the downloaded voice can save English, French, Portuguese and '
      'Spanish', () {
    expect(savableListenLanguages(testServices(dir)), ['en', 'es', 'fr', 'pt']);
  });

  test('with the phone’s own voices, every language the phone speaks can '
      'be saved too', () {
    expect(
        savableListenLanguages(
            testServices(dir, phoneVoices: phoneVoicesFor(['ru', 'de', 'ja']))),
        ['de', 'en', 'es', 'fr', 'ja', 'pt', 'ru']);
  });

  test('an English episode: every other language the voice speaks, each '
      'by its own pair', () {
    expect(offered('en'), ['es', 'fr', 'pt']);
    expect(offered('en-US'), ['es', 'fr', 'pt']);
  });

  test('a Spanish episode: into English directly, into French and '
      'Portuguese by way of English, and never into Spanish', () {
    expect(offered('es'), ['en', 'fr', 'pt']);
  });

  test('an episode in a language the voice cannot speak is still offered '
      'every language a translator reaches from it', () {
    expect(offered('ja'), ['en', 'es', 'fr', 'pt']);
    expect(offered('ru'), ['en', 'es', 'fr', 'pt']);
  });

  test('an episode in a language no translator reads is offered nothing',
      () {
    expect(offered('cy'), isEmpty);
  });

  test('the show’s language stands in when the episode has none of its '
      'own', () {
    expect(offered(null, feedLang: 'fr-FR'), ['en', 'es', 'pt']);
    expect(offered('es', feedLang: 'fr'), ['en', 'fr', 'pt']);
  });

  test('a language nobody knows is taken for English, as the chain takes '
      'it', () {
    expect(offered(null), ['es', 'fr', 'pt']);
    expect(offered('und', feedLang: ''), ['es', 'fr', 'pt']);
    expect(listenSourceLanguage(workLang: null, feedLang: null), 'en');
    expect(listenSourceLanguage(workLang: null, feedLang: 'pt-BR'), 'pt');
  });

  test('a device that cannot translate is offered nothing', () {
    expect(
        listenLanguagesFor(testServices(dir, localMlAvailable: false),
            workLang: 'en', feedLang: null),
        isEmpty);
  });

  test('what it would download is counted from the show’s language when '
      'the episode has none: a French show into Spanish needs both '
      'translators', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final profileId = await db.profilesDao.create('Ada');
    final feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://cast.test/feed', title: 'Show');
    await (db.update(db.feeds)..where((f) => f.id.equals(feedId)))
        .write(const FeedsCompanion(language: Value('fr')));
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Épisode',
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/1.mp3');
    await db.feedsDao.insertEpisode(
        workId: id,
        feedId: feedId,
        guid: 'g1',
        enclosureUrl: 'https://cast.test/1.mp3',
        publishedAtMs: 5000);
    final services = testServices(dir);

    final items = await listenDownloads(
        db: db,
        services: services,
        transcriber: TranscribeCoordinator(db: db, services: services),
        work: (await db.spineDao.workById(id))!,
        episode: (await db.feedsDao.episodeOf(id))!,
        lang: 'es');

    final labels = [for (final i in items) i.label];
    expect(labels.where((l) => l.startsWith('French to English translator')),
        hasLength(1));
    expect(labels.where((l) => l.startsWith('English to Spanish translator')),
        hasLength(1));
  });

  group('the phone’s own voices (board-0126: “russian, japanese, german, '
      'not just spanish”)', () {
    /// The starter catalog without its English to Japanese pair.
    ModelRegistry withoutEnglishToJapanese() => ModelRegistry([
          for (final s in ModelRegistry.starter().specs)
            if (s.id != 'elanmt-bt-en-ja') s,
        ]);

    List<String> offeredWith(Iterable<String> phone, String? workLang,
            {ModelRegistry? registry, String? feedLang}) =>
        listenLanguagesFor(
            testServices(dir,
                phoneVoices: phoneVoicesFor(phone), registry: registry),
            workLang: workLang,
            feedLang: feedLang);

    test('an English episode on a phone with Russian, German and Japanese '
        'voices: all three are offered beside the downloaded voice’s', () {
      expect(offeredWith(['ru', 'de', 'ja'], 'en'),
          ['de', 'es', 'fr', 'ja', 'pt', 'ru']);
    });

    test('without the English to Japanese translator, Japanese is not '
        'offered', () {
      expect(
          offeredWith(['ru', 'de', 'ja'], 'en',
              registry: withoutEnglishToJapanese()),
          ['de', 'es', 'fr', 'pt', 'ru']);
    });

    // One for each language a translator writes from English: offered
    // exactly when the phone (or the downloaded voice) can save it.
    const fromEnglish = [
      'ar', 'de', 'es', 'fr', 'hi', 'it', 'ja', 'nl', 'pt', 'ru', 'uk', //
      'zh',
    ];
    for (final lang in fromEnglish) {
      test('${languageDisplayName(lang)}: offered for an English episode '
          'with a phone voice for it', () {
        expect(offeredWith([lang], 'en'), contains(lang));
      });
      test('${languageDisplayName(lang)}: '
          '${supertonicLangsForTest.contains(lang) ? 'offered without a phone voice, by the downloaded voice' : 'not offered without a phone voice'}',
          () {
        expect(offeredWith(const [], 'en').contains(lang),
            supertonicLangsForTest.contains(lang));
      });
    }

    test('a Russian episode reaches German by way of English, and English '
        'itself', () {
      expect(offeredWith(['de', 'en'], 'ru'), ['de', 'en', 'es', 'fr', 'pt']);
    });

    test('a phone voice for a language no translator knows at all is never '
        'offered', () {
      expect(offeredWith(['cy', 'bo'], 'en'), ['es', 'fr', 'pt']);
    });

    test('a language with a translator and no voice is left out, and the '
        'note names it and says where to add a voice', () {
      final services = testServices(dir, phoneVoices: phoneVoicesFor(['ru']));
      final sorted = listenLanguagesOf(services, workLang: 'en', feedLang: null);
      expect(sorted.offered, isNot(contains('de')));
      expect(sorted.noVoice, contains('de'));
      final note =
          listenMissingNoteFor(services, workLang: 'en', feedLang: null)!;
      expect(note, contains('German'));
      expect(note, contains('no voice on this phone'));
      expect(note, contains('Text-to-speech output'));
      expect(note, isNot(contains('Russian')));
    });

    test('a language the phone speaks and no translator writes from the '
        'episode’s language is named with that reason', () {
      final services =
          testServices(dir, phoneVoices: phoneVoicesFor(['ko', 'ru']));
      expect(
          listenLanguagesOf(services, workLang: 'en', feedLang: null)
              .noTranslator,
          ['ko']);
      final note =
          listenMissingNoteFor(services, workLang: 'en', feedLang: null)!;
      expect(note, contains('Korean'));
      expect(note, contains('no translator from English'));
    });

    test('the voices are those last heard from the phone, and a voice '
        'installed since shows up when they are asked again', () async {
      final saver = FakePhoneSpeechSaver(['ru']);
      final cache = PhoneVoiceCache(saver);
      final services = testServices(dir, phoneVoices: cache);
      List<String> offered() =>
          listenLanguagesFor(services, workLang: 'en', feedLang: null);
      expect(offered(), ['es', 'fr', 'pt'], reason: 'not asked yet');
      var heard = 0;
      cache.addListener(() => heard++);
      await cache.refresh();
      expect(offered(), ['es', 'fr', 'pt', 'ru']);
      saver.langs = {'ru', 'de'};
      await cache.refresh();
      expect(offered(), ['de', 'es', 'fr', 'pt', 'ru']);
      await cache.refresh();
      expect(heard, 2, reason: 'only a real change is told');
    });
  });
}

const supertonicLangsForTest = {'en', 'es', 'fr', 'pt'};
