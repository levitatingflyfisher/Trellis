import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_prefs.dart';
import 'package:trellis/features/reader/reader_screen.dart';
import 'package:trellis/features/reader/speech/spoken_text.dart';
import 'package:trellis/services/device_services.dart';

import '../support/fake_tts.dart';

/// 1.6.0, owner: read aloud "speaks every inline citation in the personal
/// finance book, which makes it painful to listen to". By default the
/// voice skips citations, footnote marks and bare links; the page keeps
/// them; one switch in the reader's menu turns them back on.
void main() {
  late AppDatabase db;
  late FakeTtsSpeaker tts;
  late int profileId;
  late int workId;

  const enVoice = SystemVoice(name: 'en-us-x-iol-local', locale: 'en-US');

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tts = FakeTtsSpeaker(installed: [enVoice]);
    profileId = await db.profilesDao.create('Ada');
    workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'book',
        title: 'Money',
        persistence: 'work',
        firstSeenEpochDay: 100,
        lang: 'en');
    await db.spineDao.insertSegments(workId, const [
      (
        idx: 0,
        kind: 'prose',
        text: 'Saving early matters most (Smith, 2019). Fees compound over '
            'decades [12].'
      ),
      (idx: 1, kind: 'prose', text: '[13]'),
      (idx: 2, kind: 'prose', text: 'Goodbye now.'),
    ]);
    await db.profilesDao.updateReaderPrefs(profileId,
        (p) => p.copyWith(session: const ReaderSession(mode: 'scroll')));
  });
  tearDown(() => db.close());

  Future<void> pumpReader(WidgetTester tester) async {
    final work = (await db.spineDao.workById(workId))!;
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(
            db: db, profileId: profileId, work: work, tts: tts)));
    await tester.pumpAndSettle();
  }

  Future<List<String>> heard(WidgetTester tester) async {
    final onPage = find.byKey(const Key('reader-play'));
    await tester.tap(onPage.evaluate().isNotEmpty
        ? onPage
        : find.byKey(const Key('speak-toggle')));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
    }
    return [for (final u in tts.utterances) u.text];
  }

  testWidgets('by default the voice skips citations, and a block that is '
      'only one says nothing; the page keeps them', (tester) async {
    await pumpReader(tester);

    expect(await heard(tester), [
      'Saving early matters most.',
      'Fees compound over decades.',
      'Goodbye now.',
    ]);
    expect(find.textContaining('(Smith,', findRichText: true), findsWidgets);
    expect(find.textContaining('[12]', findRichText: true), findsWidgets);
  });

  Future<void> openReadingSettings(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('reader-overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reading-settings')));
    await tester.pumpAndSettle();
  }

  bool switchOn(WidgetTester tester) => tester
      .widget<SwitchListTile>(find.byKey(const Key('speak-citations-toggle')))
      .value;

  testWidgets('“Read citations aloud” in Reading settings turns them back '
      'on for this reader at once, and is remembered', (tester) async {
    await pumpReader(tester);
    await openReadingSettings(tester);
    expect(find.text('Read citations aloud'), findsOneWidget);
    expect(switchOn(tester), isFalse);
    await tester.tap(find.byKey(const Key('speak-citations-toggle')));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(await db.deviceSettingsDao.read(speakCitationsKey), 'on');
    final said = await heard(tester);
    expect(said.first, 'Saving early matters most (Smith, 2019).');
    expect(said, contains('[13]'));

    // A reader opened afresh starts with it on.
    await tester.pumpWidget(const SizedBox());
    await pumpReader(tester);
    await openReadingSettings(tester);
    expect(switchOn(tester), isTrue);
  });
}
