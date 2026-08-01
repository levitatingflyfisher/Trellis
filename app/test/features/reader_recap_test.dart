import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_screen.dart';

import 'brain_test_support.dart';

/// Campaign 4 Phase 4's "Catch me up?" — an offer chip on a work reopened
/// with real progress already made (the trigger itself, `shouldOfferRecap`,
/// is tested pure in reader_logic_test.dart; this file only proves the
/// widget wires it correctly), reusing the SAME consent order distill
/// already established: gesture -> cloud-tier consent -> Brain call.
/// Result lands in a sheet, never a full-page push, and never touches the
/// database — closing it forgets it.
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
        title: 'The Lighthouse',
        persistence: 'work',
        firstSeenEpochDay: 100);
    await db.spineDao.insertSegments(workId, const [
      (idx: 0, kind: 'prose', text: 'Ada begins the journey at dawn.'),
      (idx: 1, kind: 'prose', text: 'She meets a stranger on the road.'),
      (idx: 2, kind: 'prose', text: 'FUTURESECRET the stranger is a spy.'),
      (idx: 3, kind: 'prose', text: 'FUTURESECRET the twist ending.'),
    ]);
    work = (await db.spineDao.worksOf(profileId)).single;
  });
  tearDown(() => db.close());

  Future<void> pumpReader(WidgetTester tester,
      {FakeBrain? brain, bool offerRecap = true}) async {
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(
            db: db,
            profileId: profileId,
            work: work,
            offerRecap: offerRecap,
            brain: fakeBrainStore(secrets: secrets, brain: brain))));
    await tester.pumpAndSettle();
  }

  /// Scroll mode, tap the word unique to segment 2 — lands the cursor
  /// there so pre-cursor text is exactly segments 0 and 1. Campaign 9
  /// Phase 6: `mode-toggle` opens a labeled three-way picker rather than
  /// cycling on its own tap.
  Future<void> seekIntoSegmentTwo(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('mode-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mode-item-scroll')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('spy.'));
    await tester.pumpAndSettle();
  }

  Future<void> configureAnthropic() async {
    secrets.values[r'brain.tier'] = 'byokAnthropic';
    secrets.values['brain.anthropic_api_key'] = 'sk-ant-k';
  }

  testWidgets('offerRecap true shows the chip; false shows nothing',
      (tester) async {
    await pumpReader(tester, offerRecap: false);
    expect(find.byKey(const Key('recap-offer-chip')), findsNothing);
  });

  testWidgets('the offer chip opens the flow; dismissing it without '
      'tapping calls no Brain', (tester) async {
    await configureAnthropic();
    final brain = FakeBrain([]);
    await pumpReader(tester, brain: brain);
    expect(find.byKey(const Key('recap-offer-chip')), findsOneWidget);

    await tester.tap(find.byKey(const Key('recap-offer-dismiss')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recap-offer-chip')), findsNothing);
    expect(brain.callCount, 0);
  });

  testWidgets('no brain configured: one calm line, nothing runs',
      (tester) async {
    final brain = FakeBrain([]);
    await pumpReader(tester, brain: brain);
    await tester.tap(find.byKey(const Key('recap-offer-chip')));
    await tester.pumpAndSettle();

    expect(find.textContaining('works fully without a brain'),
        findsOneWidget);
    expect(find.byKey(const Key('consent-dialog')), findsNothing);
    expect(brain.callCount, 0);
  });

  testWidgets('the cloud tier passes consent first, naming the host — a '
      'no moves nothing', (tester) async {
    await configureAnthropic();
    final brain = FakeBrain(['{"recap": "unreached"}']);
    await pumpReader(tester, brain: brain);
    await tester.tap(find.byKey(const Key('recap-offer-chip')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('consent-dialog')), findsOneWidget);
    expect(find.textContaining('api.anthropic.com'), findsOneWidget);

    await tester.tap(find.byKey(const Key('consent-cancel')));
    await tester.pumpAndSettle();
    expect(brain.callCount, 0);
    expect(find.byKey(const Key('recap-sheet')), findsNothing);
  });

  testWidgets('the prompt carries only text before the cursor — nothing '
      'at or after it reaches the model', (tester) async {
    await configureAnthropic();
    final brain = FakeBrain(['{"recap": "Ada met a stranger on the road."}']);
    await pumpReader(tester, brain: brain);
    await seekIntoSegmentTwo(tester);

    await tester.tap(find.byKey(const Key('recap-offer-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('consent-accept')));
    await tester.pumpAndSettle();

    expect(brain.callCount, 1);
    final prompt = brain.prompts.single;
    expect(prompt, contains('Ada begins the journey at dawn.'));
    expect(prompt, contains('She meets a stranger on the road.'));
    expect(prompt, isNot(contains('FUTURESECRET')),
        reason: 'segments at/after the cursor must never reach the prompt');

    expect(find.byKey(const Key('recap-sheet')), findsOneWidget);
    expect(find.textContaining('Ada met a stranger'), findsOneWidget);
    expect(find.textContaining('fake-model'), findsOneWidget);
  });

  testWidgets('a malformed reply shows the calm typed failure inside the '
      'sheet, not a crash', (tester) async {
    await configureAnthropic();
    final brain = FakeBrain(['not json at all']);
    await pumpReader(tester, brain: brain);
    await tester.tap(find.byKey(const Key('recap-offer-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('consent-accept')));
    await tester.pumpAndSettle();

    expect(find.textContaining('could not write a recap'), findsOneWidget);
  });

  testWidgets('the regenerate button re-asks the Brain without a second '
      'consent dialog for the same already-approved text', (tester) async {
    await configureAnthropic();
    final brain = FakeBrain([
      '{"recap": "First pass."}',
      '{"recap": "Second pass."}',
    ]);
    await pumpReader(tester, brain: brain);
    await tester.tap(find.byKey(const Key('recap-offer-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('consent-accept')));
    await tester.pumpAndSettle();
    expect(find.textContaining('First pass.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('recap-sheet-regenerate')));
    await tester.pumpAndSettle();

    expect(brain.callCount, 2);
    expect(find.byKey(const Key('consent-dialog')), findsNothing);
    expect(find.textContaining('Second pass.'), findsOneWidget);
  });

  testWidgets('the offer bar survives 320dp at 2x text scale — the fleet\'s '
      'recurring rigid-row wound', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);

    await pumpReader(tester);
    expect(find.byKey(const Key('recap-offer-chip')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
