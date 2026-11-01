import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/listen/listen_chain.dart';
import 'package:trellis/features/listen/listen_in_language_bar.dart';
import 'package:trellis/features/models/consent.dart';
import 'package:trellis/features/reader/speech/speech_engine.dart';

import '../support/fake_services.dart';

/// The one tap on an episode's page (1.6.0): the learning language is
/// asked once, downloads are agreed to once, and the same button then
/// makes the spoken episode and plays it.
void main() {
  late Directory dir;
  late AppDatabase db;
  late Work work;
  late List<int> played;
  late List<bool> fresh;
  late List<DownloadItem> downloads;
  late int transcribed;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('trellis-listen-bar');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final profileId = await db.profilesDao.create('Ada');
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
    played = [];
    fresh = [];
    downloads = [];
    transcribed = 0;
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  ListenChain chain() => ListenChain(
        db: db,
        transcribe: (w, e) async {
          transcribed++;
          await db.spineDao.insertSegments(
              w.id, const [(idx: 0, kind: 'prose', text: 'Hello there.')]);
          await db.spineDao.insertAlignments(
              w.id, const [(segmentIdx: 0, tStartMs: 0, tEndMs: 2000)]);
        },
        translate: (w, source, target, progress) async {
          await db.spineDao.upsertTranslationSentence(
              workId: w.id,
              segmentIdx: 0,
              sentenceIdx: 0,
              lang: target,
              sourceText: 'Hello there.',
              body: 'Hola.');
          return null;
        },
        voiceFor: (lang) async => (
          name: 'Test voice',
          say: (String t) async =>
              SynthResult(samples: Float32List(100), sampleRate: 1000),
        ),
        audioFileFor: testServices(dir).audioFileFor,
        tempDir: Directory('${dir.path}/tmp'),
      );

  Future<void> pump(WidgetTester tester, ListenChain c,
      {List<String> languages = const ['es']}) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ListenInLanguageBar(
                db: db,
                chain: c,
                work: work,
                languages: languages,
                downloadsFor: (lang) async => downloads,
                onPlay: (id, {required justMade}) async {
                  played.add(id);
                  fresh.add(justMade);
                }))));
    await tester.pumpAndSettle();
  }

  testWidgets('the first tap asks the learning language once, then makes '
      'the episode and plays it; the button then carries the language',
      (tester) async {
    await tester.runAsync(() async {
      await pump(tester, chain());
      expect(find.text('Listen in another language'), findsOneWidget);

      await tester.tap(find.byKey(const Key('listen-in-language')));
      await tester.pumpAndSettle();
      expect(find.text('Which language are you learning?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('learning-language-es')));
      for (var i = 0; i < 20 && played.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }

      expect(played, hasLength(1));
      expect(transcribed, 1);
      expect(await db.deviceSettingsDao.read(learningLanguageKey), 'es');
      await tester.pump();
      expect(find.text('Listen in Spanish'), findsOneWidget);
    });
  });

  testWidgets('with the language known, one tap is all: no question, and '
      'a second tap plays what was made without making it again',
      (tester) async {
    await tester.runAsync(() async {
      await db.deviceSettingsDao.write(learningLanguageKey, 'es');
      final c = chain();
      await pump(tester, c);
      expect(find.text('Listen in Spanish'), findsOneWidget);

      for (var tap = 0; tap < 2; tap++) {
        await tester.tap(find.byKey(const Key('listen-in-language')));
        for (var i = 0; i < 20 && played.length <= tap; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump();
        }
      }

      expect(find.text('Which language are you learning?'), findsNothing);
      expect(played, hasLength(2));
      expect(played.first, played.last);
      // The page is told which it was: the end of a job that may have
      // run for half an hour, or a tap on something already made. Only
      // the tap may cut into what is playing.
      expect(fresh, [true, false]);
      expect(transcribed, 1);
    });
  });

  testWidgets('what it would download is agreed to once, first; a no '
      'starts nothing', (tester) async {
    await db.deviceSettingsDao.write(learningLanguageKey, 'es');
    downloads = const [DownloadItem('English to Spanish translator, 115 MB')];
    await pump(tester, chain());

    await tester.tap(find.byKey(const Key('listen-in-language')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('consent-dialog')), findsOneWidget);
    expect(find.textContaining('English to Spanish translator'),
        findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    expect(transcribed, 0);
    expect(played, isEmpty);
  });

  testWidgets('with no language this device can save, there is no button',
      (tester) async {
    await pump(tester, chain(), languages: const []);

    expect(find.byKey(const Key('listen-in-language')), findsNothing);
  });
}
