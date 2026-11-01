import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/episodes/episode_actions.dart';
import 'package:trellis/features/listen/listen_chain.dart';
import 'package:trellis/features/listen/listen_device.dart';
import 'package:trellis/features/listen/listen_jobs.dart';
import 'package:trellis/features/reader/speech/phone_voice.dart';
import 'package:trellis/features/settings/settings_screen.dart';
import 'package:trellis/main.dart';

import '../../support/fake_player.dart';
import '../../support/fake_services.dart';
import '../../support/pick_reader.dart';
import '../../support/scripted_fetcher.dart';
import '../../support/tabs.dart';

/// Board-0128, owner: he could not find where to set the language he is
/// learning. It is a plain row in Settings (board-0132: every app-wide
/// setting is there, on the bottom bar), saying what is chosen, and it
/// opens the same list as an episode's page, for every language some
/// episode could be made in.
void main() {
  late Directory dir;
  late AppDatabase db;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('trellis-learning-setting');
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  ListenJobs jobsOver(FakePhoneSpeechSaver saver) {
    final services = testServices(dir, phoneVoices: PhoneVoiceCache(saver));
    return ListenJobs(
      db: db,
      chain: ListenChain(
        db: db,
        transcribe: (w, e) async {},
        translate: (w, s, t, p) async => null,
        voiceFor: (w, l) async => null,
        audioFileFor: services.audioFileFor,
        tempDir: Directory('${dir.path}/tmp'),
      ),
      languagesFor: ({required workLang, required feedLang}) =>
          listenLanguagesFor(services, workLang: workLang, feedLang: feedLang),
      sortedFor: ({required workLang, required feedLang}) =>
          listenLanguagesOf(services, workLang: workLang, feedLang: feedLang),
      sortedForAny: () => listenLanguagesAnywhere(services),
      abilities: () => deviceLanguageAbilities(services),
      askVoices: services.phoneVoices.refresh,
      openVoiceSettings: saver.openSettings,
      downloadsFor: (w, e, l) async => const [],
    );
  }

  Future<void> pumpSettings(WidgetTester tester, ListenJobs jobs) async {
    final profileId = await db.profilesDao.create('Ada');
    await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
            db: db,
            profile: (await db.profilesDao.all()).single,
            onSwitchProfile: () {},
            actions: EpisodeActions(
                db: db, profileId: profileId, listenJobs: jobs))));
    await tester.pumpAndSettle();
  }

  Finder rowSays(String words) => find.descendant(
      of: find.byKey(const Key('learning-language-setting')),
      matching: find.text(words));

  Future<void> openPicker(WidgetTester tester) async {
    final row = find.byKey(const Key('learning-language-setting'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  /// The list is lazy: scroll a row into view, as a person would.
  Future<void> reach(WidgetTester tester, String key) async {
    await tester.scrollUntilVisible(find.byKey(Key(key)), 120,
        scrollable: find.descendant(
            of: find.byKey(const Key('learning-language-list')),
            matching: find.byType(Scrollable)));
    expect(find.byKey(Key(key)), findsOneWidget, reason: key);
  }

  Future<void> search(WidgetTester tester, String words) async {
    await tester.enterText(
        find.byKey(const Key('learning-language-search')), words);
    await tester.pumpAndSettle();
  }

  testWidgets('Settings has a Learning language row that says '
      '“Not chosen”, opens every language with what works in it, and then '
      'names the choice', (tester) async {
    final jobs = jobsOver(FakePhoneSpeechSaver(['ru', 'de', 'ja']));
    await tester.runAsync(() => jobs.ready);
    await pumpSettings(tester, jobs);
    expect(rowSays('Not chosen'), findsOneWidget);

    await openPicker(tester);
    expect(find.byKey(const Key('learning-language-dialog')), findsOneWidget);
    expect(find.text('Episodes can be made in these'), findsOneWidget);
    // From English or from any language Trellis translates, with a voice.
    for (final l in ['de', 'ru', 'ja', 'es']) {
      await reach(tester, 'learning-language-$l');
    }

    await reach(tester, 'learning-language-ru');
    await tester.tap(find.byKey(const Key('learning-language-ru')));
    await tester.pumpAndSettle();
    expect(await db.deviceSettingsDao.read(learningLanguageKey), 'ru');
    expect(rowSays('Russian'), findsOneWidget);
  });

  testWidgets('any language can be chosen, even one nothing translates or '
      'speaks; its row says so plainly', (tester) async {
    final jobs = jobsOver(FakePhoneSpeechSaver(['ru']));
    await tester.runAsync(() => jobs.ready);
    await pumpSettings(tester, jobs);
    await openPicker(tester);

    await search(tester, 'wel');
    final welsh = find.byKey(const Key('learning-language-cy'));
    expect(welsh, findsOneWidget);
    expect(
        tester.getSemantics(welsh).label,
        'Welsh. Reading works. Cards work. Transcribing needs a download. '
        'Translating is not there yet. Speaking is not there yet.');
    await tester.tap(welsh);
    await tester.pumpAndSettle();

    expect(await db.deviceSettingsDao.read(learningLanguageKey), 'cy');
    expect(rowSays('Welsh'), findsOneWidget);
  });

  testWidgets('the list holds every language Trellis can name', (tester) async {
    final jobs = jobsOver(FakePhoneSpeechSaver(const []));
    await tester.runAsync(() => jobs.ready);
    await pumpSettings(tester, jobs);
    await openPicker(tester);
    for (final (words, code) in [
      ('swahili', 'sw'),
      ('cantonese', 'yue'),
      ('icelandic', 'is'),
      ('zu', 'zu'),
    ]) {
      await search(tester, words);
      expect(find.byKey(Key('learning-language-$code')), findsOneWidget,
          reason: words);
    }
  });

  for (final scale in [1.0, 2.0, 3.0]) {
    testWidgets('at 320 dp and ${scale}x text the picker does not overflow',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final jobs = jobsOver(FakePhoneSpeechSaver(['ru']));
      await tester.runAsync(() => jobs.ready);
      await pumpSettings(tester, jobs);
      await openPicker(tester);
      await search(tester, 'Portuguese');
      expect(tester.takeException(), isNull);
      await reach(tester, 'learning-language-pt');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the Settings tab names the chosen language', (tester) async {
    final saver = FakePhoneSpeechSaver(['ru']);
    final profileId = await db.profilesDao.create('Ada');
    await db.deviceSettingsDao.write(learningLanguageKey, 'ru');
    expect(profileId, isPositive);
    final player = FakeEpisodePlayer();
    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((u, h) => textResponse('')),
        createPlayer: () => player,
        services: testServices(dir, phoneVoices: PhoneVoiceCache(saver))));
    await tester.pumpAndSettle();
    await pickReader(tester, 'Ada');

    await toTab(tester, 'Settings');
    expect(rowSays('Russian'), findsOneWidget);
  });
}
