import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/models/asr_choice_section.dart';
import 'package:trellis/features/transcribe/asr_choice.dart';
import 'package:trellis/features/transcribe/transcribe_coordinator.dart';

import '../support/fake_services.dart';

/// Model tiers, first step (1.6.0, owner: "providing bigger model options
/// … if a person has a better phone that can do better transcribing … I
/// want it"). The small transcription model stays the default on every
/// phone; a larger one is the listener's own choice, never a guess about
/// their phone.
void main() {
  final registry = ModelRegistry.starter();

  group('which model transcribes', () {
    test('with no choice made, the tier’s own: the small one on an '
        'ordinary phone', () {
      expect(asrModelFor(registry, DeviceTier.t1, null)!.id,
          'whisper-tiny-ggml');
    });

    test('a chosen larger model is used even on an ordinary phone: it is '
        'the listener’s call', () {
      expect(asrModelFor(registry, DeviceTier.t1, 'whisper-base-ggml')!.id,
          'whisper-base-ggml');
    });

    test('a choice that names no transcription model falls back to the '
        'default', () {
      expect(asrModelFor(registry, DeviceTier.t1, 'gone-model')!.id,
          'whisper-tiny-ggml');
      expect(asrModelFor(registry, DeviceTier.t1, 'silero-vad')!.id,
          'whisper-tiny-ggml');
    });

    test('the choices are every transcription model, smallest first, each '
        'with plain words', () {
      final choices = asrChoices(registry);
      expect([for (final c in choices) c.id],
          ['whisper-tiny-ggml', 'whisper-base-ggml', 'whisper-small-ggml']);
      expect([for (final c in choices) asrChoiceTitle(c)],
          ['Fast', 'More accurate', 'Most accurate']);
      expect(asrChoiceNote(choices[0]), contains('43.5 MB'));
      expect(asrChoiceNote(choices[1]), contains('81.8 MB'));
      expect(asrChoiceNote(choices[1]), contains('slow'));
      expect(asrChoiceNote(choices[2]), contains('264.5 MB'));
      expect(asrChoiceNote(choices[2]), contains('strong phone'));
    });
  });

  group('the coordinator', () {
    late AppDatabase db;
    late Directory dir;
    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      dir = Directory.systemTemp.createTempSync('trellis-asr-choice');
    });
    tearDown(() async {
      await db.close();
      dir.deleteSync(recursive: true);
    });

    test('plans with the small model until another is chosen, then with '
        'the chosen one', () async {
      final coordinator =
          TranscribeCoordinator(db: db, services: testServices(dir));

      expect(
          (await coordinator.planFor(
                  workId: 1, enclosureUrl: 'https://cast.test/1.mp3'))
              .model
              .id,
          'whisper-tiny-ggml');

      await db.deviceSettingsDao.write(asrModelKey, 'whisper-base-ggml');

      expect(
          (await coordinator.planFor(
                  workId: 1, enclosureUrl: 'https://cast.test/1.mp3'))
              .model
              .id,
          'whisper-base-ggml');
    });
  });

  group('the choice on the Models page', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(
                  child: AsrChoiceSection(
                      db: db, registry: registry, tier: DeviceTier.t1)))));
      await tester.pumpAndSettle();
    }

    testWidgets('shows both, with the small one chosen until another is',
        (tester) async {
      await pump(tester);

      expect(find.text('Transcription quality'), findsOneWidget);
      expect(find.text('Fast'), findsOneWidget);
      expect(find.text('More accurate'), findsOneWidget);
      expect(find.text('Most accurate'), findsOneWidget);
      expect(
          tester
              .widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
              .groupValue,
          'whisper-tiny-ggml');
    });

    testWidgets('choosing the larger one is remembered', (tester) async {
      await pump(tester);

      await tester.tap(find.byKey(const Key('asr-choice-whisper-base-ggml')));
      await tester.pumpAndSettle();

      expect(await db.deviceSettingsDao.read(asrModelKey),
          'whisper-base-ggml');
      await tester.pumpWidget(const SizedBox());
      await pump(tester);
      expect(
          tester
              .widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
              .groupValue,
          'whisper-base-ggml');
    });
  });
}
