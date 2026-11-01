import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/listen/listen_jobs.dart'
    show learningLanguageKey;
import 'package:trellis/features/listen/spoken_share.dart'
    show shareClonedVoiceAudioKey;
import 'package:trellis/features/settings/settings_screen.dart';
import 'package:trellis/services/device_services.dart' show SystemVoice;

import '../brain_test_support.dart';

/// The Settings screen's own rows (board-0132): each setting that used to
/// hide in some tab's ⋮ works here the way it worked there.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<Profile> seedProfile() async {
    final id = await db.profilesDao.create('Ada');
    return (await db.profilesDao.all()).firstWhere((p) => p.id == id);
  }

  Future<void> pumpSettings(WidgetTester tester, Profile profile,
      {bool localMlAvailable = false,
      Future<List<SystemVoice>?> Function()? listVoices,
      VoidCallback? onOpenEcho}) async {
    await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
            db: db,
            profile: profile,
            onSwitchProfile: () {},
            localMlAvailable: localMlAvailable,
            listVoices: listVoices,
            brainStore: fakeBrainStore(secrets: InMemorySecretStore()),
            onOpenEcho: onOpenEcho)));
    await tester.pumpAndSettle();
  }

  Future<void> tapRow(WidgetTester tester, Key key) async {
    await tester.ensureVisible(find.byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
  }

  bool switchOn(WidgetTester tester, Key key) =>
      tester.widget<SwitchListTile>(find.byKey(key)).value;

  group('FSRS scheduling (ADR-0009), moved here from Courses’ ⋮', () {
    testWidgets('is on for a fresh profile, with no “beta”', (tester) async {
      final profile = await seedProfile();
      expect(await db.profilesDao.scheduler(profile.id), 'fsrs');
      await pumpSettings(tester, profile);
      expect(switchOn(tester, const Key('scheduler-toggle')), isTrue);
      expect(find.textContaining('beta'), findsNothing);
    });

    testWidgets('turning it on explains FSRS and says progress carries '
        'over before it takes effect; confirming flips it', (tester) async {
      final profile = await seedProfile();
      await db.profilesDao.setScheduler(profile.id, 'classic');
      await pumpSettings(tester, profile);

      await tapRow(tester, const Key('scheduler-toggle'));
      expect(find.textContaining('progress carries over'), findsOneWidget);
      expect(await db.profilesDao.scheduler(profile.id), 'classic');

      await tester.tap(find.text('Use FSRS'));
      await tester.pumpAndSettle();
      expect(await db.profilesDao.scheduler(profile.id), 'fsrs');
      expect(switchOn(tester, const Key('scheduler-toggle')), isTrue);
    });

    testWidgets('declining leaves Classic in place', (tester) async {
      final profile = await seedProfile();
      await db.profilesDao.setScheduler(profile.id, 'classic');
      await pumpSettings(tester, profile);

      await tapRow(tester, const Key('scheduler-toggle'));
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(await db.profilesDao.scheduler(profile.id), 'classic');
      expect(switchOn(tester, const Key('scheduler-toggle')), isFalse);
    });

    testWidgets('turning it off is instant, with no dialog', (tester) async {
      final profile = await seedProfile();
      await pumpSettings(tester, profile);

      await tapRow(tester, const Key('scheduler-toggle'));
      expect(find.text('Use FSRS'), findsNothing);
      expect(await db.profilesDao.scheduler(profile.id), 'classic');
    });
  });

  group('the household default to trim silence (Campaign 6), moved here '
      'from Subscriptions’ ⋮', () {
    testWidgets('starts off, and a tap turns it on', (tester) async {
      final profile = await seedProfile();
      await pumpSettings(tester, profile, localMlAvailable: true);
      expect(switchOn(tester, const Key('dsp-global-default-toggle')),
          isFalse);
      await tapRow(tester, const Key('dsp-global-default-toggle'));
      expect(await db.profilesDao.dspGlobalDefault(profile.id), isTrue);
    });

    testWidgets('shows on when it is on, and a tap turns it off',
        (tester) async {
      final profile = await seedProfile();
      await db.profilesDao.setDspGlobalDefault(profile.id, true);
      await pumpSettings(tester, profile, localMlAvailable: true);
      expect(
          switchOn(tester, const Key('dsp-global-default-toggle')), isTrue);
      await tapRow(tester, const Key('dsp-global-default-toggle'));
      expect(await db.profilesDao.dspGlobalDefault(profile.id), isFalse);
    });

    testWidgets('is not offered where nothing can be processed (the web)',
        (tester) async {
      await pumpSettings(tester, await seedProfile());
      expect(find.byKey(const Key('dsp-global-default-toggle')), findsNothing);
    });
  });

  group('Share audio made in a host’s own voice', () {
    testWidgets('is under Listening, off by default, and a tap turns it on',
        (tester) async {
      final profile = await seedProfile();
      await pumpSettings(tester, profile, localMlAvailable: true);
      const key = Key('share-cloned-voice-toggle');
      expect(switchOn(tester, key), isFalse);
      expect(await db.deviceSettingsDao.read(shareClonedVoiceAudioKey),
          isNull);

      await tapRow(tester, key);
      expect(switchOn(tester, key), isTrue);
      expect(await db.deviceSettingsDao.read(shareClonedVoiceAudioKey), '1');

      await tapRow(tester, key);
      expect(switchOn(tester, key), isFalse);
      expect(await db.deviceSettingsDao.read(shareClonedVoiceAudioKey), '0');
    });

    testWidgets('is not offered where nothing can be made (the web)',
        (tester) async {
      final profile = await seedProfile();
      await pumpSettings(tester, profile);
      expect(find.byKey(const Key('share-cloned-voice-toggle')), findsNothing);
    });
  });

  testWidgets('Thinking (AI helper) opens the Thinking settings',
      (tester) async {
    await pumpSettings(tester, await seedProfile());
    await tapRow(tester, const Key('open-thinking'));
    expect(find.text('Thinking'), findsOneWidget);
    expect(find.byKey(const Key('no-brain-note')), findsOneWidget);
  });

  testWidgets('What you’ve built names itself and opens', (tester) async {
    var opened = 0;
    await pumpSettings(tester, await seedProfile(), onOpenEcho: () => opened++);
    expect(find.text('What you’ve built'), findsOneWidget);
    await tapRow(tester, const Key('open-echo'));
    expect(opened, 1);
  });

  testWidgets('Read citations aloud is a switch here, and is remembered',
      (tester) async {
    await pumpSettings(tester, await seedProfile());
    expect(switchOn(tester, const Key('speak-citations-toggle')), isFalse);
    await tapRow(tester, const Key('speak-citations-toggle'));
    expect(await db.deviceSettingsDao.read('read_aloud_citations'), 'on');
  });

  testWidgets('Read aloud voices offers a voice for every language this '
      'reader meets: the learning language, a work’s and a show’s',
      (tester) async {
    final profile = await seedProfile();
    await db.deviceSettingsDao.write(learningLanguageKey, 'ru');
    await db.spineDao.insertWork(
        profileId: profile.id,
        kind: 'book',
        title: 'Un livre',
        persistence: 'kept',
        firstSeenEpochDay: 1,
        lang: 'fr');
    final feedId = await db.feedsDao
        .insertFeed(profileId: profile.id, url: 'https://cast.test/feed');
    await db.feedsDao.updateRefreshState(feedId,
        title: 'Ein Podcast',
        etag: null,
        lastModified: null,
        breakerJson: '{}',
        language: 'de',
        updateLanguage: true);
    await pumpSettings(tester, profile,
        localMlAvailable: true, listVoices: () async => const []);

    await tapRow(tester, const Key('settings-read-aloud-voices'));
    final sheet = find.byKey(const Key('read-aloud-voices-sheet'));
    expect(sheet, findsOneWidget);
    for (final name in ['French', 'German', 'Russian']) {
      expect(
          find.descendant(of: sheet, matching: find.textContaining(name)),
          findsWidgets,
          reason: name);
    }
  });
}
