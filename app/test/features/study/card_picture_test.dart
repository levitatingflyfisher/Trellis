import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_core/study_core.dart' as study;
import 'package:trellis/db/database.dart';
import 'package:trellis/features/study/card_editing.dart';
import 'package:trellis/features/study/card_editor_screen.dart';
import 'package:trellis/features/study/card_images.dart';
import 'package:trellis/features/study/study_session_screen.dart';

import '../brain_test_support.dart';

/// Pictures on cards, on screen (owner, 28 Oct: "I don't see anything
/// stolen from mochi or from anki on having cloze and images"): the
/// editor picks one, and a session shows it from the device alone.
void main() {
  // A real one-pixel PNG, so the test decodes what a phone would.
  final pixel = base64.decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAC'
      'hwGA60e6kgAAAABJRU5ErkJggg==');

  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  group('the editor', () {
    CardDraft? saved;
    Uint8List? next;
    setUp(() {
      saved = null;
      next = null;
    });

    Future<void> pumpEditor(WidgetTester tester, {CardDraft? initial}) async {
      await tester.pumpWidget(MaterialApp(
          home: CardEditorScreen(
              title: 'Add card',
              initial: initial,
              pictures: CardPictures(db, pick: () async => next),
              onSave: (d, _) async => saved = d)));
      await tester.pumpAndSettle();
    }

    Future<void> tapAndSettle(WidgetTester tester, String key) async {
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.tap(find.byKey(Key(key)));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
    }

    testWidgets('a picked picture shows, and the card saves with it',
        (tester) async {
      await pumpEditor(tester);
      final add = find.byKey(const Key('card-picture-add'));
      expect(tester.getSize(add).height, greaterThanOrEqualTo(48));
      expect(find.byTooltip('Pick a picture to show with this card'),
          findsOneWidget);
      next = Uint8List.fromList(pixel);
      await tester.enterText(find.byKey(const Key('card-front')), 'What?');
      await tester.enterText(find.byKey(const Key('card-back')), 'A dot.');
      await tapAndSettle(tester, 'card-picture-add');
      expect(find.byKey(const Key('card-picture')), findsOneWidget);
      await tester.tap(find.byKey(const Key('card-save')));
      await tester.pumpAndSettle();
      final name = cardImageNameOf(Uint8List.fromList(pixel));
      expect(saved, CardDraft.frontBack('What?', 'A dot.', image: name));
      expect(await tester.runAsync(() => db.studyDao.cardImage(name)), pixel);
    });

    testWidgets('a card’s picture can be taken off', (tester) async {
      final name = await tester.runAsync(
          () => keepCardImage(db, Uint8List.fromList(pixel)));
      await pumpEditor(tester,
          initial: CardDraft.cloze('A {{c1::dot}}.', image: name));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('card-picture')), findsOneWidget);
      expect(find.byTooltip('Show no picture with this card'), findsOneWidget);
      await tapAndSettle(tester, 'card-picture-remove');
      expect(find.byKey(const Key('card-picture')), findsNothing);
      await tester.tap(find.byKey(const Key('card-save')));
      await tester.pumpAndSettle();
      expect(saved, const CardDraft.cloze('A {{c1::dot}}.'));
    });

    testWidgets('a file that is not a picture is refused in plain words',
        (tester) async {
      await pumpEditor(tester);
      next = Uint8List.fromList(utf8.encode('%PDF-1.7'));
      await tapAndSettle(tester, 'card-picture-add');
      expect(
          find.text('This file isn’t a picture Trellis can show. Pick a PNG, '
              'JPEG, GIF or WebP.'),
          findsOneWidget);
      expect(find.byKey(const Key('card-picture')), findsNothing);
    });

    testWidgets('picking nothing changes nothing', (tester) async {
      await pumpEditor(tester);
      await tapAndSettle(tester, 'card-picture-add');
      expect(find.byKey(const Key('card-picture')), findsNothing);
      expect(find.byKey(const Key('card-error')), findsNothing);
    });

    testWidgets('without a store there is no picture to add', (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: CardEditorScreen(
              title: 'Add card', onSave: (d, _) async => saved = d)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('card-picture-add')), findsNothing);
    });
  });

  group('a session', () {
    String course({required String image}) => json.encode({
          'schemaVersion': '1.0',
          'id': 'birds',
          'title': 'Birds',
          'nodes': [
            {
              'id': 'n',
              'title': 'Shore birds',
              'intake': '',
              'items': [
                {
                  'id': 'i',
                  'type': 'qa',
                  'rung': 3,
                  'prompt': 'What bird is this?',
                  'answer': 'A heron.',
                  'image': image,
                },
              ],
            },
          ],
        });

    Future<void> pumpSession(WidgetTester tester, String raw) async {
      final row = await tester.runAsync(() async {
        final profileId = await db.profilesDao.create('Ada');
        final id = await db.studyDao
            .importCourse(profileId: profileId, raw: raw, nowMs: 1);
        return (await db.studyDao.courseRowById(id))!;
      });
      await tester.pumpWidget(MaterialApp(
          home: StudySessionScreen(
              db: db,
              courseRowId: row!.id,
              course: study.parseCourseString(row.raw),
              brainStore: fakeBrainStore(secrets: InMemorySecretStore()))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('begin-session')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the card’s picture from the device', (tester) async {
      final name = cardImageNameOf(Uint8List.fromList(pixel));
      await tester.runAsync(
          () => db.studyDao.putCardImage(name, Uint8List.fromList(pixel)));
      await pumpSession(tester, course(image: name));
      expect(find.text('What bird is this?'), findsOneWidget);
      final image = tester.widget<Image>(find.byKey(const Key('card-picture')));
      expect(image.semanticLabel, 'The card’s picture');
    });

    testWidgets('says plainly when the picture is not on this device',
        (tester) async {
      await pumpSession(tester, course(image: 'gone.png'));
      expect(find.text('What bird is this?'), findsOneWidget);
      expect(find.text('This card’s picture isn’t on this device.'),
          findsOneWidget);
    });
  });
}

