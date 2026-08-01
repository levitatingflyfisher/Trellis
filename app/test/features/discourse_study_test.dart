import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_core/study_core.dart' as study;
import 'package:trellis/db/database.dart';
import 'package:trellis/features/study/study_session_screen.dart';

import 'brain_test_support.dart';

/// Discourse study (proposal-2 §6/§7): a course that carries discourse
/// prompts offers them in the session — they travel with the file, so they
/// work on zero-ML devices; a configured Brain adds ONLY a critique with a
/// SUGGESTED grade behind the consent chokepoint. The learner's tap is the
/// only thing that ever reaches the scheduler, and a distilled course names
/// its provenance on the session door.
void main() {
  late AppDatabase db;
  late InMemorySecretStore secrets;
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    secrets = InMemorySecretStore();
  });
  tearDown(() => db.close());

  /// The distillable fixture plus a provenance stamp — the shape the
  /// Distiller actually saves.
  String provenancedCourse() {
    final json = distillableCourseJson();
    json['provenance'] = {
      'brainTier': 'byokAnthropic',
      'modelId': 'fake-model',
    };
    return jsonEncode(json);
  }

  String plainQaCourse() => jsonEncode({
        'schemaVersion': '1.0',
        'id': 'plain',
        'title': 'No Discourse Here',
        'nodes': [
          {
            'id': 'n1',
            'title': 'Only Node',
            'intake': 'Water is wet.',
            'items': [
              {
                'id': 'i-qa',
                'type': 'qa',
                'rung': 3,
                'prompt': 'Why wet?',
                'answer': 'Because water.',
                'acceptable': ['water'],
                'rubric': 'Mention water.',
              },
            ],
          },
        ],
      });

  Future<(int, study.Course)> import(String raw) async {
    await db.profilesDao.create('Ada');
    final id =
        await db.studyDao.importCourse(profileId: 1, raw: raw, nowMs: 1);
    return (id, study.parseCourseString(raw));
  }

  Future<void> pumpSession(WidgetTester tester, int courseRowId,
      study.Course course, {FakeBrain? brain}) async {
    await tester.pumpWidget(MaterialApp(
        home: StudySessionScreen(
            db: db,
            courseRowId: courseRowId,
            course: course,
            brainStore: fakeBrainStore(secrets: secrets, brain: brain))));
    await tester.pumpAndSettle();
  }

  void configureAnthropic() {
    secrets.values['brain.tier'] = 'byokAnthropic';
    secrets.values['brain.anthropic_api_key'] = 'sk-ant-k';
  }

  testWidgets('discourse prompts travel with the course and work with NO '
      'brain — never graded, never scheduled', (tester) async {
    final (id, course) = await import(provenancedCourse());
    await pumpSession(tester, id, course);

    // The declaration names the prompts; the door shows who distilled.
    expect(find.text('1 item · 1 concept · 2 prompts'), findsOneWidget);
    expect(find.byKey(const Key('course-provenance')), findsOneWidget);
    expect(find.textContaining('fake-model'), findsOneWidget);

    await tester.tap(find.byKey(const Key('begin-session')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recall'));
    await tester.pumpAndSettle();

    // Discourse step 1 (socratic). No brain: no critique affordance.
    expect(find.text('What would break if the first idea were false?'),
        findsOneWidget);
    expect(find.byKey(const Key('discourse-critique')), findsNothing);
    await tester.enterText(find.byKey(const Key('discourse-n1-0')),
        'It would all fall down.');
    await tester.tap(find.byKey(const Key('discourse-continue')));
    await tester.pumpAndSettle();

    // Discourse step 2 (explain back), then the ordinary item.
    expect(find.text('Explain the first idea in your own words.'),
        findsOneWidget);
    await tester.tap(find.byKey(const Key('discourse-continue')));
    await tester.pumpAndSettle();

    expect(find.text('What is the first idea?'), findsOneWidget);
    await tester.enterText(
        find.byKey(const Key('recall-n1-i1')), 'the first idea');
    await tester.tap(find.text('Reveal answer'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Easy'));
    await tester.pumpAndSettle();

    // Only the ITEM was reviewed; discourse fed no scheduler, no revlog.
    expect(find.text('You reviewed 1 item.'), findsOneWidget);
    expect(await db.studyDao.revlogOf(id), hasLength(1));
  });

  testWidgets('a course without discourse declares itself exactly as '
      'today', (tester) async {
    final (id, course) = await import(plainQaCourse());
    await pumpSession(tester, id, course);
    expect(find.text('1 item · 1 concept'), findsOneWidget);
    expect(find.byKey(const Key('course-provenance')), findsNothing);
  });

  testWidgets('a discourse critique passes the consent chokepoint, shows '
      'the critique with provenance, and touches no schedule',
      (tester) async {
    configureAnthropic();
    final brain = FakeBrain([
      '{"critique":"Named the idea; missing the why.",'
          '"suggestedGrade":"hard"}',
    ]);
    final (id, course) = await import(provenancedCourse());
    await pumpSession(tester, id, course, brain: brain);
    await tester.tap(find.byKey(const Key('begin-session')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recall'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('discourse-n1-0')),
        'It would all fall down.');
    await tester.tap(find.byKey(const Key('discourse-critique')));
    await tester.pumpAndSettle();

    // THE chokepoint, naming the destination, before any byte.
    expect(find.byKey(const Key('consent-dialog')), findsOneWidget);
    expect(find.textContaining('api.anthropic.com'), findsOneWidget);
    await tester.tap(find.byKey(const Key('consent-accept')));
    await tester.pumpAndSettle();

    expect(brain.callCount, 1);
    expect(brain.prompts.single, contains('It would all fall down.'));
    expect(find.textContaining('Named the idea; missing the why.'),
        findsOneWidget);
    expect(find.textContaining('hard'), findsOneWidget,
        reason: 'the model\'s read is shown as words, not a decision');
    expect(find.textContaining('Critique by fake-model'), findsOneWidget);
    expect(await db.studyDao.revlogOf(id), isEmpty,
        reason: 'discourse never reaches the scheduler');
  });

  testWidgets('refusing critique consent moves nothing', (tester) async {
    configureAnthropic();
    final brain = FakeBrain([]);
    final (id, course) = await import(provenancedCourse());
    await pumpSession(tester, id, course, brain: brain);
    await tester.tap(find.byKey(const Key('begin-session')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recall'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('discourse-critique')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('consent-cancel')));
    await tester.pumpAndSettle();
    expect(brain.callCount, 0);
  });

  testWidgets('free recall: the model may SUGGEST a grading — the '
      'learner\'s tap is the only thing that drives the SRS',
      (tester) async {
    configureAnthropic();
    final brain = FakeBrain([
      '{"critique":"Right substance, thin reasoning.",'
          '"suggestedGrade":"hard"}',
    ]);
    final (id, course) = await import(plainQaCourse());
    await pumpSession(tester, id, course, brain: brain);
    await tester.tap(find.byKey(const Key('begin-session')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recall'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const Key('recall-i-qa')), 'because of water');
    await tester.tap(find.text('Reveal answer'));
    await tester.pumpAndSettle();

    // Keyword coverage suggested Easy; the brain affordance is offered.
    expect(find.widgetWithText(FilledButton, 'Easy'), findsOneWidget);
    await tester.tap(find.byKey(const Key('brain-suggest')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('consent-accept')));
    await tester.pumpAndSettle();

    // The critique rides the rubric; the highlight moves to the model's
    // suggestion — a highlight, never a decision.
    expect(brain.prompts.single, contains('Mention water.'));
    expect(find.textContaining('Right substance, thin reasoning.'),
        findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Hard'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Easy'), findsOneWidget);

    // The learner overrules the model. Their tap is the law. (The grade
    // row sits below the critique box — bring it on screen first.)
    await tester.ensureVisible(find.widgetWithText(OutlinedButton, 'Good'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Good'));
    await tester.pumpAndSettle();
    final log = await db.studyDao.revlogOf(id);
    expect(log.single.grade, 'good',
        reason: 'the tap drives the SRS, not the model');
  });

  testWidgets('an unusable critique degrades calmly — self-rating stands',
      (tester) async {
    configureAnthropic();
    final brain = FakeBrain(['this is not json']);
    final (id, course) = await import(plainQaCourse());
    await pumpSession(tester, id, course, brain: brain);
    await tester.tap(find.byKey(const Key('begin-session')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recall'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const Key('recall-i-qa')), 'because of water');
    await tester.tap(find.text('Reveal answer'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('brain-suggest')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('consent-accept')));
    await tester.pumpAndSettle();

    expect(find.textContaining('could not write a critique'),
        findsOneWidget);
    // The keyword suggestion still stands; grading still works.
    expect(find.widgetWithText(FilledButton, 'Easy'), findsOneWidget);
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Easy'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Easy'));
    await tester.pumpAndSettle();
    expect((await db.studyDao.revlogOf(id)).single.grade, 'easy');
  });
}
