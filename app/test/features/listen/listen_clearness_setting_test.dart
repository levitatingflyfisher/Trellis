import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/episodes/episode_actions.dart';
import 'package:trellis/features/listen/listen_chain.dart';
import 'package:trellis/features/listen/listen_clearness.dart';
import 'package:trellis/features/listen/listen_jobs.dart';
import 'package:trellis/features/settings/settings_screen.dart';

/// The founding request's follow-up: "Bonus points if I can choose how
/// much they enunciate". A plain row in Settings, under Learning, beside
/// the learning language: How clearly the voice speaks, Natural until
/// changed, four steps that each say what they do.
void main() {
  late Directory dir;
  late AppDatabase db;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('trellis-clearness-setting');
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  ListenJobs jobs() => ListenJobs(
        db: db,
        chain: ListenChain(
          db: db,
          transcribe: (w, e) async {},
          translate: (w, s, t, p) async => null,
          voiceFor: (w, l) async => null,
          audioFileFor: (id, url) => File('${dir.path}/$id'),
          tempDir: Directory('${dir.path}/tmp'),
        ),
        languagesFor: ({required workLang, required feedLang}) => const [],
        downloadsFor: (w, e, l) async => const [],
      );

  Future<void> pumpSettings(WidgetTester tester, ListenJobs j) async {
    final profileId = await db.profilesDao.create('Ada');
    await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
            db: db,
            profile: (await db.profilesDao.all()).single,
            onSwitchProfile: () {},
            actions: EpisodeActions(
                db: db, profileId: profileId, listenJobs: j))));
    await tester.pumpAndSettle();
  }

  Finder rowSays(String words) => find.descendant(
      of: find.byKey(const Key('listen-clearness-setting')),
      matching: find.text(words));

  testWidgets('the row says Natural, opens the four steps with what each '
      'does, and keeps the one chosen', (tester) async {
    final j = jobs();
    await tester.runAsync(() => j.ready);
    await pumpSettings(tester, j);

    final row = find.byKey(const Key('listen-clearness-setting'));
    expect(row, findsOneWidget);
    expect(rowSays('How clearly the voice speaks'), findsOneWidget);
    expect(rowSays('Natural'), findsOneWidget);
    // Under Learning, just after the learning language.
    expect(tester.getTopLeft(row).dy,
        greaterThan(tester.getTopLeft(
            find.byKey(const Key('learning-language-setting'))).dy));

    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    final dialog = find.byKey(const Key('listen-clearness-dialog'));
    expect(dialog, findsOneWidget);
    for (final c in ListenClearness.values) {
      final option = find.byKey(Key('listen-clearness-${c.name}'));
      expect(
          find.descendant(of: option, matching: find.text(c.label)),
          findsOneWidget);
      expect(find.descendant(of: option, matching: find.text(c.help)),
          findsOneWidget);
      expect(tester.getSize(option).height, greaterThanOrEqualTo(48),
          reason: c.name);
    }
    // Honest about the casual end of the request.
    expect(
        find.descendant(
            of: dialog, matching: find.textContaining('more casual')),
        findsOneWidget);

    await tester.tap(find.byKey(const Key('listen-clearness-slow')));
    await tester.pumpAndSettle();

    expect(await tester.runAsync(() => readListenClearness(db)),
        ListenClearness.slow);
    expect(j.clearness, ListenClearness.slow);
    expect(rowSays('Slow and clear'), findsOneWidget);
  });

  testWidgets('a step chosen before is named when the app starts',
      (tester) async {
    await tester.runAsync(
        () => writeListenClearness(db, ListenClearness.verySlow));
    final j = jobs();
    await tester.runAsync(() => j.ready);
    await pumpSettings(tester, j);
    expect(rowSays('Very slow'), findsOneWidget);
  });
}
