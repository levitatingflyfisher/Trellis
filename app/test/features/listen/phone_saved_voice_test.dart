import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/listen/listen_device.dart';
import 'package:trellis/features/listen/saved_voice.dart';
import 'package:trellis/features/reader/reader_prefs.dart';
import 'package:trellis/features/reader/speech/phone_voice.dart';
import 'package:trellis/features/transcribe/transcribe_coordinator.dart';
import 'package:trellis/services/device_services.dart' show SystemVoice;

import '../../support/fake_services.dart';

/// Which voice saves an episode's audio (board-0126). The downloaded
/// voice (Supertonic) where it speaks the language and is on the device;
/// else the phone's own voice for that language; else none. The listener
/// can change it in the one place voices are already chosen: Read aloud's
/// voices, per language.
void main() {
  group('the rule', () {
    SavedVoiceKind? pick(
            {bool speaks = false,
            bool here = false,
            bool phone = false,
            String? choice}) =>
        savedVoiceKind(
            downloadedSpeaks: speaks,
            downloadedHere: here,
            phoneSpeaks: phone,
            choice: choice);

    test('the downloaded voice, when it speaks the language and is here',
        () {
      expect(pick(speaks: true, here: true, phone: true),
          SavedVoiceKind.downloaded);
      expect(pick(speaks: true, here: true), SavedVoiceKind.downloaded);
    });

    test('else the phone’s own voice: nothing is fetched when the phone can '
        'already say it', () {
      expect(pick(speaks: true, phone: true), SavedVoiceKind.phone);
      expect(pick(phone: true), SavedVoiceKind.phone);
    });

    test('else the downloaded voice, fetched once with the listener’s yes',
        () {
      expect(pick(speaks: true), SavedVoiceKind.downloaded);
    });

    test('else none', () {
      expect(pick(), isNull);
      expect(pick(choice: readAloudNeuralVoice), isNull);
      expect(pick(choice: readAloudDefaultVoice), isNull);
    });

    test('a phone voice chosen for the language in Read aloud saves it, even '
        'with the downloaded voice here', () {
      expect(
          pick(speaks: true, here: true, phone: true,
              choice: readAloudDefaultVoice),
          SavedVoiceKind.phone);
      expect(
          pick(speaks: true, here: true, phone: true,
              choice: '${readAloudSystemVoicePrefix}es-x-eee-local'),
          SavedVoiceKind.phone);
    });

    test('the downloaded voice chosen in Read aloud saves it, even when it '
        'has to be fetched first', () {
      expect(pick(speaks: true, phone: true, choice: readAloudNeuralVoice),
          SavedVoiceKind.downloaded);
    });

    test('a choice that can’t be kept falls back to the rule', () {
      expect(pick(speaks: true, choice: readAloudDefaultVoice),
          SavedVoiceKind.downloaded);
      expect(pick(phone: true, choice: readAloudNeuralVoice),
          SavedVoiceKind.phone);
    });
  });

  group('on this device', () {
    late Directory dir;
    late AppDatabase db;
    late int profileId;
    late Work work;
    late Episode episode;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('trellis-phone-voice');
      db = AppDatabase.forTesting(NativeDatabase.memory());
      profileId = await db.profilesDao.create('Ada');
      final feedId = await db.feedsDao.insertFeed(
          profileId: profileId, url: 'https://cast.test/feed', title: 'Show');
      final id = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: 'Harbour',
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
      episode = (await db.feedsDao.episodeOf(id))!;
    });
    tearDown(() async {
      await db.close();
      dir.deleteSync(recursive: true);
    });

    ({FakePhoneSpeechSaver saver, PhoneVoiceCache cache}) phone(
        List<String> langs) {
      final saver = FakePhoneSpeechSaver(langs);
      return (
        saver: saver,
        cache: PhoneVoiceCache(saver,
            known: PhoneVoices(
                engine: saver.engine,
                voices: [
                  for (final l in langs)
                    SystemVoice(name: '$l-x-local', locale: l),
                ])),
      );
    }

    test('Russian is saved with the phone’s voice, named plainly, a sentence '
        'at a time, and its files are gone after', () async {
      final p = phone(['ru']);
      final services = testServices(dir, phoneVoices: p.cache);
      final chain = deviceListenChain(
          db: db,
          services: services,
          transcriber: TranscribeCoordinator(db: db, services: services));

      final voice = (await chain.voiceFor(work, 'ru'))!;
      expect(voice.name,
          'the phone’s own voice, Speech Services by Google');
      final said = await voice.say('Привет.');
      expect(p.saver.said, [('Привет.', 'ru', null)]);
      expect(said.sampleRate, 24000);
      expect(said.samples.length, 'Привет.'.length * 2400);
      final temp = Directory('${dir.path}/spoken-temp');
      expect(
          temp.existsSync()
              ? temp.listSync(recursive: true).whereType<File>()
              : const <File>[],
          isEmpty);
    });

    test('an engine that gives no name of its own is still named plainly',
        () {
      expect(phoneVoiceName(null), 'the phone’s own voice');
      expect(phoneVoiceName(''), 'the phone’s own voice');
    });

    test('a language with no voice anywhere has no saved voice', () async {
      final services = testServices(dir, phoneVoices: phone(['ru']).cache);
      final chain = deviceListenChain(
          db: db,
          services: services,
          transcriber: TranscribeCoordinator(db: db, services: services));
      expect(await chain.voiceFor(work, 'de'), isNull);
    });

    test('the voice picked for the language in Read aloud is the one that '
        'saves it', () async {
      await db.profilesDao.updateReaderPrefs(
          profileId,
          (p) => p.copyWith(
              voices: {'es': '${readAloudSystemVoicePrefix}es-x-local'}));
      final p = phone(['es']);
      final services = testServices(dir, phoneVoices: p.cache);
      final chain = deviceListenChain(
          db: db,
          services: services,
          transcriber: TranscribeCoordinator(db: db, services: services));
      final voice = (await chain.voiceFor(work, 'es'))!;
      await voice.say('Hola.');
      expect(p.saver.said, [('Hola.', 'es', 'es-x-local')]);
    });

    Future<List<String>> downloads(PhoneVoiceCache cache, String lang) async {
      final services = testServices(dir, phoneVoices: cache);
      final items = await listenDownloads(
          db: db,
          services: services,
          transcriber: TranscribeCoordinator(db: db, services: services),
          work: work,
          episode: episode,
          lang: lang);
      return [for (final i in items) i.label];
    }

    test('saving with the phone’s voice fetches no voice: the consent lists '
        'only the translator', () async {
      final ru = await downloads(phone(['ru']).cache, 'ru');
      expect(ru.where((l) => l.contains('Supertonic')), isEmpty);
      expect(ru.where((l) => l.startsWith('English to Russian translator')),
          hasLength(1));
      final es = await downloads(phone(['es']).cache, 'es');
      expect(es.where((l) => l.contains('Supertonic')), isEmpty);
    });

    test('with no phone voice for it, Spanish still fetches the downloaded '
        'voice, and says so first', () async {
      final es = await downloads(phone(const []).cache, 'es');
      expect(es.where((l) => l.contains('Supertonic')), hasLength(1));
    });
  });
}
