import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/listen/listen_chain.dart';
import 'package:trellis/features/listen/listen_device.dart';
import 'package:trellis/features/listen/listen_jobs.dart';
import 'package:trellis/features/reader/speech/phone_voice.dart';

import '../../support/fake_services.dart';

/// "Which language are you learning?" (board-0126): the languages that
/// can be made, by plain name, and below them why one a listener may look
/// for is missing, with the way to add a voice.
void main() {
  late Directory dir;
  late AppDatabase db;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('trellis-learning-dialog');
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  ListenJobs jobsOver(FakePhoneSpeechSaver saver) {
    final services =
        testServices(dir, phoneVoices: PhoneVoiceCache(saver));
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
      askVoices: services.phoneVoices.refresh,
      openVoiceSettings: saver.openSettings,
      downloadsFor: (w, e, l) async => const [],
    );
  }

  Future<void> open(WidgetTester tester, ListenJobs jobs) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => jobs.pickLanguage(
              context,
              jobs.languagesOfForTest(workLang: 'en', feedLang: null),
              of: (workLang: 'en', feedLang: null)),
          child: const Text('ask'),
        ),
      ),
    ));
    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();
  }

  testWidgets('a phone with Russian, German and Japanese voices: all three '
      'are listed by name for an English episode', (tester) async {
    final saver = FakePhoneSpeechSaver(['ru', 'de', 'ja']);
    final jobs = jobsOver(saver);
    await tester.runAsync(() => jobs.ready);
    await open(tester, jobs);

    for (final name in [
      'German', 'Russian', 'Japanese', 'Spanish', 'French'
    ]) {
      expect(
          find.descendant(
              of: find.byKey(const Key('learning-language-dialog')),
              matching: find.widgetWithText(SimpleDialogOption, name)),
          findsOneWidget,
          reason: name);
    }
    final note = tester
        .widget<Text>(find.byKey(const Key('learning-language-missing')))
        .data!;
    expect(note, isNot(contains('Japanese')));
    expect(note, contains('no voice on this phone for'));
    expect(note, contains('Italian'));
  });

  testWidgets('a language with a translator and no voice is absent, named in '
      'the note, and the settings page is one tap away; a voice added '
      'there shows up on coming back', (tester) async {
    final saver = FakePhoneSpeechSaver(['ru']);
    final jobs = jobsOver(saver);
    await tester.runAsync(() => jobs.ready);
    await open(tester, jobs);

    expect(find.byKey(const Key('learning-language-de')), findsNothing);
    expect(
        tester
            .widget<Text>(find.byKey(const Key('learning-language-missing')))
            .data,
        contains('German'));
    await tester.tap(find.byKey(const Key('learning-language-voice-settings')));
    await tester.pump();
    expect(saver.settingsOpened, 1);

    // Back from Android's settings with a German voice installed.
    saver.langs = {'ru', 'de'};
    await tester.runAsync(jobs.refreshVoices);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('learning-language-de')), findsOneWidget);
  });

  testWidgets('nothing missing, nothing said', (tester) async {
    final saver = FakePhoneSpeechSaver(
        ['ar', 'de', 'hi', 'it', 'ja', 'nl', 'ru', 'uk', 'zh']);
    final jobs = jobsOver(saver);
    await tester.runAsync(() => jobs.ready);
    await open(tester, jobs);
    expect(find.byKey(const Key('learning-language-missing')), findsNothing);
    expect(find.byKey(const Key('learning-language-voice-settings')),
        findsNothing);
  });

  // Seen on the emulator: "Change" on an episode's page opened an empty,
  // dimmed screen. The page asked without saying which episode, and the
  // dialog read the missing list with `!`.
  testWidgets('asked without an episode, the dialog still lists the '
      'languages', (tester) async {
    final saver = FakePhoneSpeechSaver(['ru']);
    final jobs = jobsOver(saver);
    await tester.runAsync(() => jobs.ready);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => jobs.pickLanguage(context, const ['es', 'ru']),
          child: const Text('ask'),
        ),
      ),
    ));
    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(SimpleDialogOption, 'Russian'), findsOneWidget);
  });

  test('the episode page says which episode it asks about, so the note '
      'about missing languages shows there too', () {
    final page = File('lib/features/works/work_page.dart').readAsStringSync();
    final change = page.substring(page.indexOf("Key('learning-language-change')"));
    final call = change.substring(0, change.indexOf('child:'));
    expect(call, contains('of: ('));
  });

  test('the phone is asked for its voices before anything is offered',
      () async {
    final saver = FakePhoneSpeechSaver(['ru']);
    final jobs = jobsOver(saver);
    await jobs.ready;
    expect(jobs.languagesOfForTest(workLang: 'en', feedLang: null),
        contains('ru'));
  });

  test('the app asks the phone again each time it comes back to the front',
      () {
    final shell =
        File('lib/features/profiles/home_shell.dart').readAsStringSync();
    final resumed = shell.substring(
        shell.indexOf('void didChangeAppLifecycleState('),
        shell.indexOf('Future<void> _stopJobsForRestore('));
    expect(resumed, contains('AppLifecycleState.resumed'));
    expect(resumed, contains('refreshVoices()'));
  });
}
