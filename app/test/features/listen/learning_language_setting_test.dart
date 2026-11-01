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

  testWidgets('Settings has a Learning language row that says '
      '“Not chosen”, opens the list of every language that can be made, '
      'and then names the choice', (tester) async {
    final jobs = jobsOver(FakePhoneSpeechSaver(['ru', 'de', 'ja']));
    await tester.runAsync(() => jobs.ready);
    await pumpSettings(tester, jobs);

    final row = find.byKey(const Key('learning-language-setting'));
    expect(row, findsOneWidget);
    expect(rowSays('Not chosen'), findsOneWidget);

    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    final dialog = find.byKey(const Key('learning-language-dialog'));
    expect(dialog, findsOneWidget);
    // From English or from any language Trellis translates, with a voice.
    for (final name in ['German', 'Russian', 'Japanese', 'Spanish']) {
      expect(
          find.descendant(
              of: dialog,
              matching: find.widgetWithText(SimpleDialogOption, name)),
          findsOneWidget,
          reason: name);
    }
    // The note on why a language is missing is there with no episode too.
    expect(
        tester
            .widget<Text>(find.byKey(const Key('learning-language-missing')))
            .data,
        contains('no voice on this phone for'));

    await tester.tap(find.byKey(const Key('learning-language-ru')));
    await tester.pumpAndSettle();
    expect(await db.deviceSettingsDao.read(learningLanguageKey), 'ru');

    expect(rowSays('Russian'), findsOneWidget);
  });

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
