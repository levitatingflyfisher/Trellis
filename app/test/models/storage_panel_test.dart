import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/models/models_screen.dart';

import '../support/fake_services.dart';

/// The storage panel on "On this device": real on-disk bytes for models,
/// cached episode audio, leftover decoded PCM and the database file; the
/// clear buttons delete ONLY cache — works and segments stay (data stays,
/// cache goes).
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('trellis-storage'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester,
      {FakeModelStore? store, File? databaseFile}) async {
    // A tall surface so the whole panel is laid out without scroll churn.
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final s = store ?? FakeModelStore();
    await tester.pumpWidget(MaterialApp(
        home: ModelsScreen(
            store: s,
            registry: ModelRegistry.starter(),
            services: testServices(dir, modelStore: s),
            databaseFile: databaseFile)));
    await tester.pumpAndSettle();
  }

  File audioFile(int workId) =>
      testServices(dir).audioFileFor(workId, 'https://x/ep.mp3')
        ..parent.createSync(recursive: true);
  File pcmFile(int workId) => testServices(dir).pcmFileFor(workId)
    ..parent.createSync(recursive: true);

  testWidgets('models occupying disk show their real byte counts',
      (tester) async {
    final store = FakeModelStore(downloadedIds: {'whisper-tiny-ggml'})
      ..partial['silero-vad'] = 1200;
    await pump(tester, store: store);

    final whisper = find.byKey(const Key('storage-model-whisper-tiny-ggml'));
    expect(whisper, findsOneWidget);
    expect(find.descendant(of: whisper, matching: find.text('43.5 MB')),
        findsOneWidget, reason: 'installed = the exact pinned bytes');

    final silero = find.byKey(const Key('storage-model-silero-vad'));
    expect(find.descendant(of: silero, matching: find.text('1.2 kB')),
        findsOneWidget, reason: 'a paused partial is honest disk usage too');

    expect(
        find.byKey(const Key('storage-model-qwen2.5-0.5b-instruct-litert')),
        findsNothing,
        reason: 'a model with no bytes on disk is not storage');
  });

  testWidgets('audio, PCM and database rows show real file sizes',
      (tester) async {
    audioFile(7).writeAsBytesSync(List.filled(5000, 1));
    pcmFile(7).writeAsBytesSync(List.filled(4000, 2));
    final dbFile = File('${dir.path}/trellis.sqlite')
      ..writeAsBytesSync(List.filled(2500, 3));

    await pump(tester, databaseFile: dbFile);

    expect(
        find.descendant(
            of: find.byKey(const Key('storage-audio')),
            matching: find.text('5.0 kB')),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const Key('storage-pcm')),
            matching: find.text('4.0 kB')),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const Key('storage-db')),
            matching: find.text('2.5 kB')),
        findsOneWidget);
  });

  testWidgets('the database row is skipped when no file is reachable',
      (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('storage-db')), findsNothing,
        reason: 'an in-memory db has no file to measure — skip, not crash');
  });

  testWidgets('clearing audio/PCM deletes cache only — works/segments stay',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final pid = await db.profilesDao.create('Ada');
    final workId = await db.spineDao.insertWork(
        profileId: pid,
        kind: 'episode',
        title: 'Ep 7',
        persistence: 'work',
        firstSeenEpochDay: 100);
    await db.spineDao.insertSegments(workId, [
      (idx: 0, kind: 'prose', text: 'Ola mundo.'),
      (idx: 1, kind: 'prose', text: 'Tudo bem?'),
    ]);
    final audio = audioFile(workId)..writeAsBytesSync(List.filled(5000, 1));
    final pcm = pcmFile(workId)..writeAsBytesSync(List.filled(4000, 2));

    await pump(tester);

    await tester.tap(find.byKey(const Key('storage-audio-clear')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('storage-clear-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('storage-clear-confirm')));
    await tester.pumpAndSettle();

    expect(audio.existsSync(), isFalse);
    expect(pcm.existsSync(), isTrue,
        reason: 'clearing audio must not touch decoded PCM');

    await tester.tap(find.byKey(const Key('storage-pcm-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('storage-clear-confirm')));
    await tester.pumpAndSettle();
    expect(pcm.existsSync(), isFalse);

    // The law: cache deletion never reaches the spine.
    expect((await db.spineDao.worksOf(pid)).single.title, 'Ep 7');
    expect(await db.spineDao.segmentCount(workId), 2);
  });

  testWidgets('Keep cancels a clear', (tester) async {
    final audio = audioFile(3)..writeAsBytesSync(List.filled(5000, 1));
    await pump(tester);

    await tester.tap(find.byKey(const Key('storage-audio-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('storage-clear-cancel')));
    await tester.pumpAndSettle();

    expect(audio.existsSync(), isTrue);
  });
}
