import 'package:brain_wiring/brain_wiring.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/brain/brain_settings_screen.dart';
import 'package:trellis/features/brain/brain_store.dart';
import 'package:trellis/features/study/courses_screen.dart';

import 'brain_test_support.dart';

/// The Thinking screen (proposal-2 §7 wiring): the tier is pinned by the
/// user's tap and nothing else; the BYOK key lives only in the secret
/// store, shows masked, and deleting it deletes it; with nothing set the
/// screen plainly says study works fully without a brain; the local-model
/// tier is offered only where local ML exists (web-tier honesty).
void main() {
  late InMemorySecretStore secrets;
  late BrainStore store;
  setUp(() {
    secrets = InMemorySecretStore();
    store = BrainStore(secrets: secrets);
  });

  Future<void> pumpThinking(WidgetTester tester,
      {bool localMlAvailable = true}) async {
    await tester.pumpWidget(MaterialApp(
        home: BrainSettingsScreen(
            store: store, localMlAvailable: localMlAvailable)));
    await tester.pumpAndSettle();
  }

  testWidgets('with nothing set, the screen plainly says study works '
      'fully without a brain', (tester) async {
    await pumpThinking(tester);
    expect(find.byKey(const Key('no-brain-note')), findsOneWidget);
    expect(find.textContaining('works fully without a brain'),
        findsWidgets);
  });

  testWidgets('a tier is pinned by the tap and persists', (tester) async {
    await pumpThinking(tester);
    await tester.tap(find.byKey(const Key('tier-byokAnthropic')));
    await tester.pumpAndSettle();

    final sel = await store.selection();
    expect(sel.pinnedByUser, isTrue);
    expect(sel.tier, BrainTier.byokAnthropic);

    // A fresh open shows the pinned choice still selected.
    await tester.pumpWidget(const SizedBox());
    await pumpThinking(tester);
    final group = tester.widget<RadioGroup<BrainTier>>(
        find.byType(RadioGroup<BrainTier>));
    expect(group.groupValue, BrainTier.byokAnthropic);
  });

  testWidgets('the key: saved only to the secret store, shown masked, '
      'never raw, and deleting deletes it', (tester) async {
    const raw = 'sk-ant-api03-verysecret-tail1234';
    await store.pinTier(BrainTier.byokAnthropic);
    await pumpThinking(tester);

    await tester.enterText(
        find.byKey(const Key('anthropic-key-field')), raw);
    await tester.tap(find.byKey(const Key('save-key')));
    await tester.pumpAndSettle();

    expect(secrets.values[BrainStore.anthropicKeyName], raw,
        reason: 'custody is the secret store and nothing else');
    expect(find.byKey(const Key('masked-key')), findsOneWidget);
    expect(find.textContaining('verysecret'), findsNothing,
        reason: 'the middle of the key never renders');

    await tester.tap(find.byKey(const Key('delete-key')));
    await tester.pumpAndSettle();
    expect(secrets.values.containsKey(BrainStore.anthropicKeyName), isFalse);
    expect(find.byKey(const Key('masked-key')), findsNothing);
  });

  testWidgets('Anthropic pinned without a key names the missing key',
      (tester) async {
    await store.pinTier(BrainTier.byokAnthropic);
    await pumpThinking(tester);
    expect(find.textContaining('needs its API key'), findsOneWidget);
  });

  testWidgets('the local-model tier is offered only where local ML exists',
      (tester) async {
    await pumpThinking(tester, localMlAvailable: false);
    expect(find.byKey(const Key('tier-localStub')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await pumpThinking(tester, localMlAvailable: true);
    expect(find.byKey(const Key('tier-localStub')), findsOneWidget);
  });

  testWidgets('the Courses tab offers the Thinking door', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.profilesDao.create('Ada');
    final profile = (await db.profilesDao.all()).single;

    await tester.pumpWidget(MaterialApp(
        home: CoursesScreen(db: db, profile: profile, brainStore: store)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('open-thinking')));
    await tester.pumpAndSettle();
    expect(find.text('Thinking'), findsOneWidget);
    expect(find.byKey(const Key('no-brain-note')), findsOneWidget);
  });
}
