import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:study_core/study_core.dart' as study;
import 'package:trellis/db/database.dart';
import 'package:trellis/features/backup/backup_gateway.dart';
import 'package:trellis/features/echo/echo_screen.dart';

/// Campaign 4 Phase 5's Trellis Echo: a private, reader-facing (never
/// PIN-gated — that's the parent dashboard's door) year-in-review over
/// exactly what this schema records. No "minutes listened" or "words
/// read" claim: listeningMs is furthest audio position reached (its own
/// doc comment in database.dart says so), and nothing tracks a words-read
/// count at all.
class FakeGateway implements BackupGateway {
  String? savedName;
  String? savedText;

  @override
  Future<bool> saveBytes(String suggestedName, Uint8List bytes) async {
    savedName = suggestedName;
    savedText = String.fromCharCodes(bytes);
    return true;
  }

  @override
  Future<Uint8List?> pickBytes() async => null;

  @override
  Future<String?> pickText() async => null;
}

void main() {
  late AppDatabase db;
  late Profile profile;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.profilesDao.create('Ada');
    profile = (await db.profilesDao.all()).single;
  });
  tearDown(() => db.close());

  String ladderCourse() => '''
{"schemaVersion":"1.0","id":"ladder","title":"A Ladder",
"nodes":[{"id":"a","title":"A","intake":"Water is wet.",
"items":[{"id":"i-a","type":"cloze","rung":1,"text":"Water is {{c1::wet}}.","answers":{"c1":"wet"}}]}]}
''';

  Future<void> pumpEcho(WidgetTester tester,
      {Future<void> Function(Uint8List)? shareImage,
      BackupGateway? gateway}) async {
    await tester.pumpWidget(MaterialApp(
      home: EchoScreen(
          db: db,
          profile: profile,
          shareImage: shareImage,
          gateway: gateway ?? FakeGateway()),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('a brand-new reader gets a calm empty state, no wall of '
      'zeros', (tester) async {
    await pumpEcho(tester);
    expect(find.textContaining('Nothing built yet'), findsOneWidget);
    expect(find.textContaining('0 '), findsNothing);
  });

  testWidgets('shows only what exists — never a minutes-listened or a '
      'words-read claim', (tester) async {
    final workId = await db.spineDao.insertWork(
        profileId: profile.id,
        kind: 'book',
        title: 'Kept',
        persistence: 'work',
        firstSeenEpochDay: 100);
    await db.spineDao.markFinished(workId, 120);
    await db.ledgerDao.add(profileId: profile.id, word: 'saudade', nowMs: 1);
    await db.profilesDao.recordReadingDay(profile.id, 100);
    await db.profilesDao.recordReadingDay(profile.id, 101);
    final courseRowId = await db.studyDao
        .importCourse(profileId: profile.id, raw: ladderCourse(), nowMs: 1);
    await db.studyDao.recordGrade(
        courseRowId: courseRowId,
        before: study.CardState.initial(
            'i-a', const study.SrsDefaults(), 100),
        after: study.CardState(
            itemId: 'i-a',
            ease: 2.5,
            intervalDays: 1,
            dueEpochDay: 101,
            reps: 1,
            lapses: 0),
        grade: study.Grade.good,
        tsMs: 5);
    await db.capturesDao.capture(
        profileId: profile.id, workId: workId, positionMs: 1000, nowMs: 10);

    await pumpEcho(tester);

    expect(find.text('1 work finished'), findsOneWidget);
    expect(find.text('1 word collected'), findsOneWidget);
    expect(find.text('2 days of reading'), findsOneWidget);
    expect(find.text('1 card reviewed'), findsOneWidget);
    expect(find.text('1 capture'), findsOneWidget);
    expect(find.textContaining('minutes listened'), findsNothing,
        reason: 'listeningMs is furthest position reached, not measured '
            'time — Echo must not claim more than the data supports');
    expect(find.textContaining('words read'), findsNothing,
        reason: 'nothing in this schema counts words actually read');
    expect(find.textContaining('Computed on this device'), findsOneWidget);
  });

  testWidgets('no share button when shareImage is null (the web tier)',
      (tester) async {
    await pumpEcho(tester, shareImage: null);
    expect(find.byKey(const Key('echo-share')), findsNothing);
  });

  testWidgets('the share button captures the card and hands real PNG '
      'bytes to the closure', (tester) async {
    Uint8List? shared;
    await pumpEcho(tester,
        shareImage: (bytes) async {
          shared = bytes;
        });
    expect(find.byKey(const Key('echo-share')), findsOneWidget);

    // toImage() does real asynchronous raster work the fake test clock
    // can't drive on its own — tap first (starts the async chain
    // synchronously), then runAsync to let the real Future settle
    // (never tap FROM INSIDE runAsync — that's the other landmine).
    // toImage() resolves under a normal pumpAndSettle, but PNG encoding
    // (toByteData) does real background work pumpAndSettle has no reason
    // to keep waiting for once the widget tree itself stops scheduling
    // frames — poll with real delays inside runAsync instead of trusting
    // pumpAndSettle to notice a detached unawaited Future finishing.
    await tester.tap(find.byKey(const Key('echo-share')));
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && shared == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();
    expect(shared, isNotNull);
    expect(shared!.length, greaterThan(0));
    // A PNG file always starts with this 8-byte signature.
    expect(shared!.sublist(0, 8),
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  });

  testWidgets('exporting as Markdown hands the gateway real content under '
      'a sensible name', (tester) async {
    await db.ledgerDao.add(profileId: profile.id, word: 'hygge', nowMs: 1);
    final gateway = FakeGateway();
    await pumpEcho(tester, gateway: gateway);

    await tester.tap(find.byKey(const Key('echo-export-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export as Markdown'));
    await tester.pumpAndSettle();

    expect(gateway.savedName, endsWith('.md'));
    expect(gateway.savedText, contains('hygge'));
    expect(gateway.savedText, contains('# Word ledger'));
  });

  testWidgets('exporting as JSON hands the gateway structured content',
      (tester) async {
    await db.ledgerDao.add(profileId: profile.id, word: 'hygge', nowMs: 1);
    final gateway = FakeGateway();
    await pumpEcho(tester, gateway: gateway);

    await tester.tap(find.byKey(const Key('echo-export-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export as JSON'));
    await tester.pumpAndSettle();

    expect(gateway.savedName, endsWith('.json'));
    expect(gateway.savedText, contains('"word": "hygge"'));
  });

  testWidgets('renders at 320dp and 2x text scale without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);

    final workId = await db.spineDao.insertWork(
        profileId: profile.id,
        kind: 'book',
        title: 'A Rather Longer Title Than Any List Row Would Prefer',
        persistence: 'work',
        firstSeenEpochDay: 100);
    await db.spineDao.markFinished(workId, 120);

    await pumpEcho(tester, shareImage: (_) async {});
    expect(tester.takeException(), isNull);
  });
}
