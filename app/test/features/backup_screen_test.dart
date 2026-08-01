import 'dart:convert';
import 'dart:typed_data';

import 'package:backup_core/backup_core.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/backup/backup_gateway.dart';
import 'package:trellis/features/backup/backup_screen.dart';
import 'package:trellis/features/backup/db_bridge.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/scripted_fetcher.dart';
// The shared fixtures: phrase, donor blob, seedRichly — one source of truth.
import 'backup_bridge_test.dart' as fx;

/// The Backup & migrate surface. Every filesystem touch goes through the
/// injected [BackupGateway] fake — no picker, no platform channel — and the
/// real sanctuary crypto runs to completion inside `tester.runAsync` slices
/// (fake-async law: drive the clock explicitly; never trust pumpAndSettle
/// to finish real IO).
const otherPhrase =
    'legal winner thank year wave sausage worth useful legal winner '
    'thank yellow';

class FakeGateway implements BackupGateway {
  String? savedName;
  Uint8List? savedBytes;
  Uint8List? bytesToPick;
  String? textToPick;
  bool saveResult = true;

  @override
  Future<bool> saveBytes(String suggestedName, Uint8List bytes) async {
    savedName = suggestedName;
    savedBytes = bytes;
    return saveResult;
  }

  @override
  Future<Uint8List?> pickBytes() async => bytesToPick;

  @override
  Future<String?> pickText() async => textToPick;
}

/// Pumps until [finder] matches, advancing BOTH clocks each slice: real
/// time via `runAsync` (file IO, isolate replies) and fake time via a
/// non-zero `pump` — sanctuary's PBKDF2 yields with `Future.delayed`, and a
/// zero-duration pump would leave those timers pending forever (the
/// fake-async law: drive the clock explicitly).
Future<void> pumpUntil(WidgetTester tester, Finder finder,
    {int tries = 100}) async {
  for (var i = 0; i < tries; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 200));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('never appeared: $finder');
}

void main() {
  late AppDatabase db;
  late FakeGateway gateway;
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    gateway = FakeGateway();
  });
  tearDown(() => db.close());

  Future<Profile> firstProfile() async => (await db.profilesDao.all()).first;

  Future<void> pumpScreen(WidgetTester tester, Profile profile) async {
    await tester.pumpWidget(MaterialApp(
        home: BackupScreen(db: db, profile: profile, gateway: gateway)));
    await tester.pumpAndSettle();
  }

  testWidgets('the Courses tab offers the door and the shell opens it',
      (tester) async {
    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((u, h) => textResponse('')),
        createPlayer: () => FakeEpisodePlayer()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('profile-name')), 'Ada');
    await tester.tap(find.text('Start reading'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Courses'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('open-backup')));
    await tester.pumpAndSettle();
    expect(find.text('Backup & migrate'), findsOneWidget);
  });

  testWidgets('a saved backup decrypts again under the same phrase',
      (tester) async {
    await tester.runAsync(() => fx.seedRichly(db));
    await pumpScreen(tester, await firstProfile());

    await tester.enterText(find.byKey(const Key('backup-phrase')), fx.phrase);
    await tester.tap(find.byKey(const Key('backup-save')));
    await pumpUntil(tester, find.text('Backup saved.'));

    expect(gateway.savedName, endsWith('.ohbk'));
    final decoded = await tester.runAsync(() async => RowPayload.decode(
        await EspalierBackup.decrypt(gateway.savedBytes!, phrase: fx.phrase)));
    final names =
        decoded!.tables['profiles']!.map((p) => p['name']).toSet();
    expect(names, {'Ada', 'Ben'});
  });

  testWidgets('an invalid phrase is told calmly and nothing is written',
      (tester) async {
    await tester.runAsync(() => fx.seedRichly(db));
    await pumpScreen(tester, await firstProfile());

    await tester.enterText(
        find.byKey(const Key('backup-phrase')), 'not a real phrase');
    await tester.tap(find.byKey(const Key('backup-save')));
    await pumpUntil(tester, find.byKey(const Key('backup-status')));

    final status =
        tester.widget<Text>(find.byKey(const Key('backup-status')));
    expect(status.data, contains('recovery phrase'));
    expect(gateway.savedBytes, isNull);
  });

  testWidgets('restore asks, then replaces everything', (tester) async {
    // A backup of a richly seeded device...
    final source = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(source.close);
    final blob = await tester.runAsync(() async {
      await fx.seedRichly(source);
      final payload = RowPayload.encode(
          await DbBridge(source).exportTables(),
          createdAt: DateTime.utc(2026, 8, 11));
      return EspalierBackup.encrypt(payload, phrase: fx.phrase);
    });
    // ...restored onto a device holding something else.
    await db.profilesDao.create('Zed');
    gateway.bytesToPick = blob;
    await pumpScreen(tester, await firstProfile());

    await tester.enterText(find.byKey(const Key('backup-phrase')), fx.phrase);
    await tester.tap(find.byKey(const Key('backup-restore')));
    await pumpUntil(tester, find.byKey(const Key('restore-confirm')));
    expect(find.textContaining('cannot be undone'), findsOneWidget);

    await tester.tap(find.byKey(const Key('restore-confirm')));
    await pumpUntil(tester, find.text('Backup restored.'));

    final names = (await db.profilesDao.all()).map((p) => p.name).toList();
    expect(names, ['Ada', 'Ben'], reason: 'full-replace: Zed is gone');
  });

  testWidgets('the wrong phrase opens nothing and changes nothing',
      (tester) async {
    final source = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(source.close);
    final blob = await tester.runAsync(() async {
      await fx.seedRichly(source);
      final payload = RowPayload.encode(
          await DbBridge(source).exportTables(),
          createdAt: DateTime.utc(2026, 8, 11));
      return EspalierBackup.encrypt(payload, phrase: fx.phrase);
    });
    await db.profilesDao.create('Zed');
    gateway.bytesToPick = blob;
    await pumpScreen(tester, await firstProfile());

    await tester.enterText(
        find.byKey(const Key('backup-phrase')), otherPhrase);
    await tester.tap(find.byKey(const Key('backup-restore')));
    await pumpUntil(tester, find.byKey(const Key('backup-status')));

    expect(find.textContaining("doesn't open"), findsOneWidget);
    expect((await db.profilesDao.all()).single.name, 'Zed',
        reason: 'fail closed: nothing was replaced');
  });

  testWidgets('a donor Trellis backup arrives with a calm report',
      (tester) async {
    await db.profilesDao.create('Ada');
    gateway.bytesToPick = fx.donorTrellisBlob;
    await pumpScreen(tester, await firstProfile());

    await tester.enterText(find.byKey(const Key('backup-phrase')), fx.phrase);
    await tester.tap(find.byKey(const Key('import-trellis')));
    await pumpUntil(tester, find.byKey(const Key('migration-report')));

    expect(find.text('What came across'), findsOneWidget);
    expect(find.text('• 1 courses'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    final courses = await db.studyDao.coursesOf(1);
    expect(courses.single.courseId, 'course-a');
  });

  testWidgets('an ohPrimer export arrives with a calm report',
      (tester) async {
    await db.profilesDao.create('Ada');
    gateway.textToPick = jsonEncode({
      'version': 1,
      'profile': {
        'name': 'Reader',
        'stats': {'wordsRead': 1},
        'feeds': <Object?>[],
      },
      'books': <Object?>[],
      'extracts': [
        {
          'id': 'ext::1',
          'createdAt': 1753500000000,
          'EF': 2.3,
          'reps': 1,
          'interval': 3,
          'kind': 'word',
          'focusWord': 'woods',
        },
      ],
    });
    await pumpScreen(tester, await firstProfile());

    // Plaintext donor JSON: no phrase needed — the button must not require
    // one.
    await tester.tap(find.byKey(const Key('import-primer')));
    await pumpUntil(tester, find.byKey(const Key('migration-report')));

    expect(find.text('• 1 words for the ledger'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect((await db.ledgerDao.wordsOf(1)).single.word, 'woods');
  });
}
