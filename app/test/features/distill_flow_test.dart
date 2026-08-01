import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_core/study_core.dart' as study;
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_screen.dart';

import 'brain_test_support.dart';

/// "Distill into a course" from the reader's overflow menu (proposal-2 §7):
/// the tap is the gesture, the cloud tier passes THE consent chokepoint
/// before a byte moves, the package Distiller's must-parse invariant gates
/// the save (repair budget then visible failure — never a half-import), a
/// passing course lands through the same path course_import uses, and the
/// result names its provenance. No brain configured: the menu item explains
/// in one calm line instead of running.
void main() {
  late AppDatabase db;
  late InMemorySecretStore secrets;
  late int profileId;
  late Work work;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    secrets = InMemorySecretStore();
    profileId = await db.profilesDao.create('Ada');
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'article',
        title: 'The Kalman Letter',
        persistence: 'work',
        firstSeenEpochDay: 100);
    await db.spineDao.insertSegments(workId, const [
      (idx: 0, kind: 'heading', text: 'On Estimation'),
      (idx: 1, kind: 'prose', text: 'The first idea, from the ground up.'),
      (idx: 2, kind: 'prose', text: 'It builds and it filters.'),
    ]);
    work = (await db.spineDao.worksOf(profileId)).single;
  });
  tearDown(() => db.close());

  Future<void> pumpReader(WidgetTester tester,
      {FakeBrain? brain}) async {
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(
            db: db,
            profileId: profileId,
            work: work,
            brain: fakeBrainStore(secrets: secrets, brain: brain))));
    await tester.pumpAndSettle();
  }

  Future<void> openDistill(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('reader-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Distill into a course'));
    await tester.pumpAndSettle();
  }

  Future<void> configureAnthropic() async {
    secrets.values[r'brain.tier'] = 'byokAnthropic';
    secrets.values['brain.anthropic_api_key'] = 'sk-ant-k';
  }

  testWidgets('no brain configured: one calm line, nothing runs',
      (tester) async {
    final brain = FakeBrain([]);
    await pumpReader(tester, brain: brain);
    await openDistill(tester);

    expect(find.textContaining('works fully without a brain'),
        findsOneWidget);
    expect(find.byKey(const Key('consent-dialog')), findsNothing);
    expect(brain.callCount, 0);
    expect(await db.studyDao.coursesOf(profileId), isEmpty);
  });

  testWidgets('the cloud tier passes THE consent chokepoint first — and '
      'a no is a no', (tester) async {
    await configureAnthropic();
    final brain = FakeBrain([distillableCourseText()]);
    await pumpReader(tester, brain: brain);
    await openDistill(tester);

    // The dialog names exactly where the text would go, before any byte.
    expect(find.byKey(const Key('consent-dialog')), findsOneWidget);
    expect(find.textContaining('api.anthropic.com'), findsOneWidget);
    expect(find.textContaining('The Kalman Letter'), findsWidgets);

    await tester.tap(find.byKey(const Key('consent-cancel')));
    await tester.pumpAndSettle();
    expect(brain.callCount, 0, reason: 'refused consent moves no bytes');
    expect(await db.studyDao.coursesOf(profileId), isEmpty);
  });

  testWidgets('a passing course lands via the import path and names its '
      'provenance', (tester) async {
    await configureAnthropic();
    final brain = FakeBrain([distillableCourseText()]);
    await pumpReader(tester, brain: brain);
    await openDistill(tester);
    await tester.tap(find.byKey(const Key('consent-accept')));
    await tester.pumpAndSettle();

    // The work's text went into the prompt; one clean pass.
    expect(brain.callCount, 1);
    expect(brain.prompts.single,
        contains('The first idea, from the ground up.'));

    // The success surface names the course and who thought.
    expect(find.textContaining('A Tiny Course'), findsOneWidget);
    expect(find.byKey(const Key('distill-provenance')), findsOneWidget);
    expect(find.textContaining('fake-model'), findsOneWidget);

    // Saved through the same strict-parser path course_import uses, with
    // provenance riding the course JSON itself.
    final rows = await db.studyDao.coursesOf(profileId);
    expect(rows, hasLength(1));
    final course = study.parseCourseString(rows.single.raw);
    expect(course.title, 'A Tiny Course');
    expect(rows.single.raw, contains('"brainTier": "byokAnthropic"'));
    expect(rows.single.raw, contains('"modelId": "fake-model"'));
  });

  testWidgets('the repair budget runs out into a visible failure — '
      'nothing saved', (tester) async {
    await configureAnthropic();
    final brain = FakeBrain([
      'not json at all',
      'still not json',
      '{"schemaVersion":"1.0"}',
      '{"nope":true}',
    ]);
    await pumpReader(tester, brain: brain);
    await openDistill(tester);
    await tester.tap(find.byKey(const Key('consent-accept')));
    await tester.pumpAndSettle();

    expect(brain.callCount, 4, reason: 'initial + 3 repair rounds');
    expect(find.textContaining('could not produce a valid course'),
        findsOneWidget);
    expect(await db.studyDao.coursesOf(profileId), isEmpty,
        reason: 'never a half-imported course');
  });

  testWidgets('the stove tier skips egress consent (LAN) and fails '
      'honestly while it is roadmap', (tester) async {
    secrets.values[r'brain.tier'] = 'stove';
    await pumpReader(tester);
    await openDistill(tester);

    expect(find.byKey(const Key('consent-dialog')), findsNothing,
        reason: 'LAN tiers are exempt from the egress chokepoint');
    expect(find.textContaining('household stove'), findsOneWidget);
    expect(await db.studyDao.coursesOf(profileId), isEmpty);
  });
}
