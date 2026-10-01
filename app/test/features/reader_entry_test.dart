import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_screen.dart';

import '../support/fake_speech_audio_queue.dart';
import '../support/fake_translation_service.dart';
import '../support/fake_tts.dart';

/// The work page (1.5.4) opens the reader already in a mode and a
/// language: Listen to a text starts speaking, Listen in a translation
/// speaks the translation, Read in an `mt` layer projects it, and
/// "Translate…" opens the picker.
void main() {
  late AppDatabase db;
  late FakeTtsSpeaker tts;
  late int profileId;
  late int workId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tts = FakeTtsSpeaker();
    profileId = await db.profilesDao.create('Ada');
    workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'article',
        title: 'A Story',
        persistence: 'work',
        firstSeenEpochDay: 100,
        lang: 'en');
    await db.spineDao.insertSegments(workId, const [
      (idx: 0, kind: 'prose', text: 'Hello there.'),
    ]);
  });
  tearDown(() => db.close());

  Future<void> pumpReader(WidgetTester tester,
      {bool startSpeaking = false,
      bool speakTranslation = false,
      String? layerLang,
      bool openTranslatePicker = false}) async {
    final work = (await db.spineDao.workById(workId))!;
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(
            db: db,
            profileId: profileId,
            work: work,
            tts: tts,
            createSpeechAudioQueue: FakeSpeechAudioQueue.new,
            translation: FakeTranslation().service,
            startSpeaking: startSpeaking,
            speakTranslation: speakTranslation,
            layerLang: layerLang,
            openTranslatePicker: openTranslatePicker)));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('startSpeaking reads the text aloud at once', (tester) async {
    await pumpReader(tester, startSpeaking: true);
    expect(tts.utterances.first, (text: 'Hello there.', lang: 'en'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('speakTranslation speaks the stored translation', (tester) async {
    await db.spineDao.upsertTranslationSentence(
        workId: workId,
        segmentIdx: 0,
        sentenceIdx: 0,
        lang: 'es',
        sourceText: 'Hello there.',
        body: 'Hola.');
    await db.spineDao.setActiveTranslationLang(workId, 'es');
    await pumpReader(tester, startSpeaking: true, speakTranslation: true);
    expect(tts.utterances.first, (text: 'Hola.', lang: 'es'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('layerLang projects that mt layer', (tester) async {
    await db.spineDao.insertLayers(workId, const [
      (segmentIdx: 0, lang: 'fr', kind: 'mt', text: 'Bonjour.'),
    ]);
    await pumpReader(tester, startSpeaking: true, layerLang: 'fr');
    expect(tts.utterances.first.text, 'Bonjour.');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('openTranslatePicker opens the picker', (tester) async {
    await pumpReader(tester, openTranslatePicker: true);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('translate-picker')), findsOneWidget);
  });
}
