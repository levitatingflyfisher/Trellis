import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhearth_design/openhearth_design.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/feeds/background/feed_check_section.dart';
import 'package:trellis/features/feeds/background/feed_check_settings.dart';
import 'package:trellis/features/jobs/job_center.dart';
import 'package:trellis/features/jobs/jobs_screen.dart';
import 'package:trellis/features/listen/listen_chain.dart';
import 'package:trellis/features/listen/listen_jobs.dart';
import 'package:trellis/features/listen/make_ahead.dart';
import 'package:trellis/features/listen/make_ahead_jobs.dart';
import 'package:trellis/features/listen/make_ahead_switch.dart';

import '../../support/fake_services.dart';
import '../feed_check_settings_test.dart' show FakeScheduler;

/// What a person sees of make ahead: the show's switch and the small
/// plain lines about what it made.
void main() {
  late Directory dir;
  late AppDatabase db;
  late int feedId;
  late Feed feed;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('trellis-make-ahead-ui');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final profile = await db.profilesDao.create('Ada');
    feedId = await db.feedsDao.insertFeed(
        profileId: profile, url: 'https://cast.test/feed', title: 'Show');
    feed = (await db.feedsDao.feedById(feedId))!;
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  ListenJobs jobs({List<String> can = const ['fr']}) => ListenJobs(
        db: db,
        chain: ListenChain(
          db: db,
          transcribe: (w, e) async {},
          translate: (w, s, t, p) async => null,
          voiceFor: (_, l) async => null,
          audioFileFor: testServices(dir).audioFileFor,
          tempDir: Directory('${dir.path}/tmp'),
        ),
        languagesFor: ({required workLang, required feedLang}) => can,
        downloadsFor: (w, e, l) async => const [],
        makeAhead: MakeAhead(
          db: db,
          conditionsMet: () async => false,
          modelsNeeded: (w, e, l, {required forShow}) async => const [],
          audioFileFor: testServices(dir).audioFileFor,
        ),
      );

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(MaterialApp(
        theme: OhTheme.light(), home: Scaffold(body: child)));
    await tester.pump();
  }

  testWidgets('the show’s switch says the language, is off by default, and '
      'turning it on turns it on', (tester) async {
    await tester.runAsync(() async {
      await db.deviceSettingsDao.write(learningLanguageKey, 'fr');
      final j = jobs();
      await j.ready;
      await pump(tester, MakeAheadTile(jobs: j, feed: feed));

      expect(find.text('Make new episodes in French ahead'), findsOneWidget);
      final tile = find.byKey(const Key('make-ahead-switch'));
      expect(tester.widget<SwitchListTile>(tile).value, isFalse);

      await tester.tap(tile);
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 15));
        await tester.pump();
      }
      expect(tester.widget<SwitchListTile>(tile).value, isTrue);
      expect(j.makeAhead!.isOn(feedId), isTrue);
    });
  });

  testWidgets('no language can be made for this show: there is no switch',
      (tester) async {
    await tester.runAsync(() async {
      await db.deviceSettingsDao.write(learningLanguageKey, 'fr');
      final j = jobs(can: const ['es']);
      await j.ready;
      await pump(tester, MakeAheadTile(jobs: j, feed: feed));
      expect(find.byKey(const Key('make-ahead-switch')), findsNothing);
    });
  });

  testWidgets('a line says what waits, on the show and on the Jobs page',
      (tester) async {
    await tester.runAsync(() async {
      await db.deviceSettingsDao.write(learningLanguageKey, 'fr');
      await db.deviceSettingsDao.write(
          makeAheadKey,
          AheadBook(shows: {
            feedId: (after: 0, agreedLang: null)
          }, entries: [
            AheadEntry(workId: 1, feedId: feedId, publishedAtMs: 1),
          ]).encode());
      final j = jobs();
      await j.ready;

      await pump(tester, MakeAheadTile(jobs: j, feed: feed));
      expect(find.textContaining('1 episode waiting'), findsOneWidget);

      await pump(tester, MakeAheadLine(jobs: j));
      expect(find.textContaining('1 episode waiting'), findsOneWidget);
    });
  });

  testWidgets('the Jobs page shows the line beside what is running',
      (tester) async {
    await tester.runAsync(() async {
      final center = JobCenter.forDevice(db, testServices(dir));
      addTearDown(center.dispose);
      await tester.pumpWidget(MaterialApp(
          theme: OhTheme.light(),
          home: JobsScreen(
              jobs: center, aheadLine: const Text('Made ahead: a line'))));
      await tester.pump();
      expect(find.text('Made ahead: a line'), findsOneWidget);
      expect(find.byKey(const Key('jobs-empty')), findsOneWidget);
    });
  });

  testWidgets('the limit is one setting with a few plain choices',
      (tester) async {
    await tester.runAsync(() async {
      final settings = FeedCheckSettings(db, FakeScheduler());
      await settings.load();
      expect(settings.makeAheadLimitGb, 2);
      await tester.pumpWidget(MaterialApp(
          theme: OhTheme.light(),
          home: Scaffold(
              body: SingleChildScrollView(
                  child: FeedCheckSection(settings: settings)))));
      await tester.pump();

      final limit = find.byKey(const Key('make-ahead-limit'));
      await tester.ensureVisible(limit);
      await tester.pump();
      await tester.tap(limit);
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('make-ahead-limit-5')).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(settings.makeAheadLimitGb, 5);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(await db.deviceSettingsDao.read(makeAheadLimitKey), '5',
          reason: 'the key make ahead itself reads');
    });
  });
}
