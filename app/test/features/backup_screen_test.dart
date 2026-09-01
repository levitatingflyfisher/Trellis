import 'dart:convert';
import 'dart:typed_data';

import 'package:backup_core/backup_core.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanctuary_backup_ui/testing.dart' show InMemorySecureKeyStore;
import 'package:trellis/db/database.dart';
import 'package:trellis/features/backup/backup_custody.dart';
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

  Future<void> pumpScreen(WidgetTester tester, Profile profile,
      {String Function()? newPhrase,
      BackupSealer? seal,
      BackupCustody? custody}) async {
    await tester.pumpWidget(MaterialApp(
        home: BackupScreen(
            db: db,
            profile: profile,
            gateway: gateway,
            newPhrase: newPhrase,
            seal: seal,
            custody: custody)));
    await tester.pumpAndSettle();
  }

  /// Types into the ask-back dialog (sanctuary_backup_ui's
  /// PhraseEntryDialog) — not the screen's own phrase field.
  Future<void> answerAskBack(WidgetTester tester, String words) async {
    await tester.enterText(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)),
        words);
    // 0.3.0 holds Confirm until twelve words are typed.
    await tester.pump();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
  }

  /// Checks a freshly shown phrase word by word (sanctuary_backup_ui's
  /// PhraseReEntryDialog): one word, Next, twelve times.
  Future<void> checkWords(WidgetTester tester, String words) async {
    for (final w in words.split(' ')) {
      await tester.enterText(
          find.descendant(
              of: find.byType(AlertDialog), matching: find.byType(TextField)),
          w);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('re-entry-next')));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('the Courses tab offers the door and the shell opens it',
      (tester) async {
    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((u, h) => textResponse('')),
        createPlayer: () => FakeEpisodePlayer()));
    await tester.pumpAndSettle();
    // A first launch opens straight into the new reader's Library.
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
    // A typed phrase is asked back once before anything is written — a
    // mistyped-but-valid word would otherwise lock the file for no one.
    await tester.pumpAndSettle();
    await answerAskBack(tester, fx.phrase);
    await pumpUntil(tester, find.text('Backup saved and checked.'));

    expect(gateway.savedName, endsWith('.ohbk'));
    final decoded = await tester.runAsync(() async => RowPayload.decode(
        await EspalierBackup.decrypt(gateway.savedBytes!, phrase: fx.phrase)));
    final names =
        decoded!.tables['profiles']!.map((p) => p['name']).toSet();
    expect(names, {'Ada', 'Ben'});
  });

  testWidgets("the copy names this app's phrase, not a household one",
      (tester) async {
    await db.profilesDao.create('Ada');
    await pumpScreen(tester, await firstProfile());
    // Keys derive under this app's own domain: a phrase is per app.
    expect(find.textContaining('household'), findsNothing);
    expect(find.textContaining("This app’s recovery phrase"), findsOneWidget);
  });

  testWidgets('a backup that does not re-open is never saved or reported '
      'as done', (tester) async {
    await tester.runAsync(() => fx.seedRichly(db));
    // A sealer whose output is damaged: the in-memory re-open must catch it.
    await pumpScreen(tester, await firstProfile(),
        seal: (payload, {required phrase}) async {
      final blob = await EspalierBackup.encrypt(payload, phrase: phrase);
      return Uint8List.fromList(blob)..[blob.length - 1] ^= 0xff;
    });

    await tester.enterText(find.byKey(const Key('backup-phrase')), fx.phrase);
    await tester.tap(find.byKey(const Key('backup-save')));
    await tester.pumpAndSettle();
    await answerAskBack(tester, fx.phrase);
    await pumpUntil(tester, find.byKey(const Key('backup-status')));

    expect(
        tester.widget<Text>(find.byKey(const Key('backup-status'))).data,
        contains("didn’t open again"));
    expect(gateway.savedBytes, isNull);
    expect(find.textContaining('Backup saved'), findsNothing);
  });

  group('the confirmed phrase is kept on the device (fleet key model)', () {
    Future<Uint8List> backupOf(AppDatabase source, String phrase) async {
      await fx.seedRichly(source);
      final payload = RowPayload.encode(await DbBridge(source).exportTables(),
          createdAt: DateTime.utc(2026, 8, 11));
      return EspalierBackup.encrypt(payload, phrase: phrase);
    }

    testWidgets('a minted, confirmed phrase is kept, and backups stop asking',
        (tester) async {
      await tester.runAsync(() => fx.seedRichly(db));
      final custody = MemoryBackupCustody();
      await pumpScreen(tester, await firstProfile(),
          newPhrase: () => otherPhrase, custody: custody);

      await tester.tap(find.byKey(const Key('backup-new-phrase')));
      await tester.pumpAndSettle();
      await tester.tap(find.text("I've written this down"));
      await tester.pumpAndSettle();
      await checkWords(tester, otherPhrase);

      expect(custody.phrase, otherPhrase);
      expect(find.byKey(const Key('backup-phrase')), findsNothing,
          reason: 'nothing left to type');
      expect(find.byKey(const Key('backup-phrase-kept')), findsOneWidget);

      await tester.tap(find.byKey(const Key('backup-save')));
      await pumpUntil(tester, find.text('Backup saved and checked.'));
      expect(find.text('Type your phrase again'), findsNothing);
      expect(custody.lastBackupAt, isNotNull);
    });

    testWidgets('a kept phrase backs up with no typing at all', (tester) async {
      await tester.runAsync(() => fx.seedRichly(db));
      final custody = MemoryBackupCustody(phrase: fx.phrase);
      await pumpScreen(tester, await firstProfile(), custody: custody);

      await tester.tap(find.byKey(const Key('backup-save')));
      await pumpUntil(tester, find.text('Backup saved and checked.'));
      final decoded = await tester.runAsync(() async => RowPayload.decode(
          await EspalierBackup.decrypt(gateway.savedBytes!,
              phrase: fx.phrase)));
      expect(decoded!.tables['profiles'], isNotEmpty);
    });

    testWidgets('a typed phrase confirmed once is kept for next time',
        (tester) async {
      await tester.runAsync(() => fx.seedRichly(db));
      final custody = MemoryBackupCustody();
      await pumpScreen(tester, await firstProfile(), custody: custody);

      await tester.enterText(
          find.byKey(const Key('backup-phrase')), fx.phrase);
      await tester.tap(find.byKey(const Key('backup-save')));
      await tester.pumpAndSettle();
      await answerAskBack(tester, fx.phrase);
      await pumpUntil(tester, find.text('Backup saved and checked.'));
      expect(custody.phrase, fx.phrase);
    });

    testWidgets('a mismatched typed phrase is never kept', (tester) async {
      await tester.runAsync(() => fx.seedRichly(db));
      final custody = MemoryBackupCustody();
      await pumpScreen(tester, await firstProfile(), custody: custody);

      await tester.enterText(
          find.byKey(const Key('backup-phrase')), fx.phrase);
      await tester.tap(find.byKey(const Key('backup-save')));
      await tester.pumpAndSettle();
      await answerAskBack(tester, otherPhrase);
      expect(custody.phrase, isNull);
    });

    testWidgets(
        'restoring a backup made under other words asks for them, then '
        'restores', (tester) async {
      final source = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(source.close);
      final blob = await tester.runAsync(() => backupOf(source, fx.phrase));
      await db.profilesDao.create('Zed');
      gateway.bytesToPick = blob;
      // This device keeps a different phrase than the backup was made with.
      await pumpScreen(tester, await firstProfile(),
          custody: MemoryBackupCustody(phrase: otherPhrase));

      await tester.tap(find.byKey(const Key('backup-restore')));
      await pumpUntil(tester, find.text("Enter the backup’s recovery words"));
      await tester.enterText(
          find.descendant(
              of: find.byType(AlertDialog), matching: find.byType(TextField)),
          fx.phrase);
      await tester.pump(); // 0.3.0 holds Open until twelve words are typed
      await tester.tap(find.text('Open'));
      await pumpUntil(tester, find.byKey(const Key('restore-confirm')));
      await tester.tap(find.byKey(const Key('restore-confirm')));
      await pumpUntil(tester, find.text('Backup restored.'));

      final names = (await db.profilesDao.all()).map((p) => p.name).toList();
      expect(names, ['Ada', 'Ben']);
    });

    // An in-place upgrade from the donor Trellis (sanctuary_backup_ui) can
    // leave a phrase in the same keychain that was written but never
    // acknowledged — and the donor's backups were made under it. It must
    // never be overwritten.
    testWidgets(
        'an unacknowledged phrase already on the device is offered, not '
        'replaced by a fresh one', (tester) async {
      await db.profilesDao.create('Ada');
      final keys = InMemorySecureKeyStore(mnemonic: fx.phrase);
      await pumpScreen(tester, await firstProfile(),
          newPhrase: () => otherPhrase,
          custody: SecureBackupCustody(keys: keys));

      await tester.tap(find.byKey(const Key('backup-new-phrase')));
      await tester.pumpAndSettle();
      expect(find.text('about'), findsOneWidget,
          reason: 'the words already on the device, not new ones');
      expect(find.text('legal'), findsNothing);
      await tester.tap(find.text("I've written this down"));
      await tester.pumpAndSettle();
      await checkWords(tester, fx.phrase);

      expect(await keys.readMnemonic(), fx.phrase);
      expect(await keys.readSeedAcknowledged(), isTrue);
      expect(find.byKey(const Key('backup-phrase-kept')), findsOneWidget);
    });

    testWidgets(
        'a different typed phrase backs up but never overwrites the one on '
        'the device', (tester) async {
      await tester.runAsync(() => fx.seedRichly(db));
      final keys = InMemorySecureKeyStore(mnemonic: fx.phrase);
      await pumpScreen(tester, await firstProfile(),
          custody: SecureBackupCustody(keys: keys));

      await tester.enterText(
          find.byKey(const Key('backup-phrase')), otherPhrase);
      await tester.tap(find.byKey(const Key('backup-save')));
      await tester.pumpAndSettle();
      await answerAskBack(tester, otherPhrase);
      await pumpUntil(tester, find.text('Backup saved and checked.'));

      expect(await keys.readMnemonic(), fx.phrase);
      expect(await keys.readSeedAcknowledged(), isFalse);
    });

    testWidgets('restoring under the kept phrase asks for nothing',
        (tester) async {
      final source = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(source.close);
      final blob = await tester.runAsync(() => backupOf(source, fx.phrase));
      await db.profilesDao.create('Zed');
      gateway.bytesToPick = blob;
      await pumpScreen(tester, await firstProfile(),
          custody: MemoryBackupCustody(phrase: fx.phrase));

      await tester.tap(find.byKey(const Key('backup-restore')));
      await pumpUntil(tester, find.byKey(const Key('restore-confirm')));
    });
  });

  testWidgets('a typed phrase that is not asked back the same writes nothing',
      (tester) async {
    await tester.runAsync(() => fx.seedRichly(db));
    await pumpScreen(tester, await firstProfile());

    await tester.enterText(find.byKey(const Key('backup-phrase')), fx.phrase);
    await tester.tap(find.byKey(const Key('backup-save')));
    await tester.pumpAndSettle();
    expect(find.text('Type your phrase again'), findsOneWidget);
    await answerAskBack(tester, otherPhrase);

    expect(find.byKey(const Key('backup-status')), findsOneWidget);
    expect(
        tester.widget<Text>(find.byKey(const Key('backup-status'))).data,
        contains("didn’t match"));
    expect(gateway.savedBytes, isNull);
  });

  testWidgets(
      'no phrase yet: the app mints one, shows it, asks it back, then backs up '
      'under it', (tester) async {
    await tester.runAsync(() => fx.seedRichly(db));
    // A known phrase stands in for fresh entropy so the test can type it.
    await pumpScreen(tester, await firstProfile(),
        newPhrase: () => otherPhrase);

    await tester.tap(find.byKey(const Key('backup-new-phrase')));
    await tester.pumpAndSettle();
    // The words are shown, numbered, and must be acknowledged.
    expect(find.text('Your recovery words'), findsOneWidget);
    expect(find.text('legal'), findsNWidgets(2));
    expect(find.text('yellow'), findsOneWidget);
    await tester.tap(find.text("I've written this down"));
    await tester.pumpAndSettle();

    // Checked word by word; a wrong word is named in place and kept.
    expect(find.text('Check your recovery words'), findsOneWidget);
    expect(find.text('Word 1 of 12'), findsOneWidget);
    await checkWords(tester, 'abandon');
    expect(find.textContaining("doesn't match word 1"), findsOneWidget);
    expect(find.text('Word 1 of 12'), findsOneWidget);
    await checkWords(tester, otherPhrase);
    expect(find.text('Check your recovery words'), findsNothing);

    final field =
        tester.widget<TextField>(find.byKey(const Key('backup-phrase')));
    expect(field.controller!.text, otherPhrase);

    // Already proven — saving does not ask a second time.
    await tester.tap(find.byKey(const Key('backup-save')));
    await pumpUntil(tester, find.text('Backup saved and checked.'));
    final decoded = await tester.runAsync(() async => RowPayload.decode(
        await EspalierBackup.decrypt(gateway.savedBytes!,
            phrase: otherPhrase)));
    expect(decoded!.tables['profiles'], isNotEmpty);
  });

  testWidgets('backing out of the ask-back leaves the field empty',
      (tester) async {
    await db.profilesDao.create('Ada');
    await pumpScreen(tester, await firstProfile(),
        newPhrase: () => otherPhrase);

    await tester.tap(find.byKey(const Key('backup-new-phrase')));
    await tester.pumpAndSettle();
    await tester.tap(find.text("I've written this down"));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    final field =
        tester.widget<TextField>(find.byKey(const Key('backup-phrase')));
    expect(field.controller!.text, isEmpty,
        reason: 'an unconfirmed phrase never becomes the backup key');
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
    // An error is colour + icon + word, never colour alone (dfh-03).
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
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
    // The safe answer carries the emphasis (audit mind-04); the
    // destructive one is marked as such by icon and colour, not by weight.
    expect(
        find.ancestor(
            of: find.text('Keep what I have'),
            matching: find.byType(FilledButton)),
        findsOneWidget);
    expect(
        find.ancestor(
            of: find.byKey(const Key('restore-confirm')),
            matching: find.byType(FilledButton)),
        findsNothing);
    expect(
        find.descendant(
            of: find.byKey(const Key('restore-confirm')),
            matching: find.byIcon(Icons.report_outlined)),
        findsOneWidget);

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

    expect(find.textContaining("doesn’t open"), findsOneWidget);
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
