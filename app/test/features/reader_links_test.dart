import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_logic.dart';
import 'package:trellis/features/reader/reader_prefs.dart';
import 'package:trellis/features/reader/reader_screen.dart';

/// Links in the reader (1.6.2). 1.6.1 kept a Markdown link's address in
/// the text but it could not be tapped, and in brackets a long address
/// showed as "…". A link's word now looks like a link, and a tap on it
/// asks, as show notes do, then opens it.
void main() {
  group('which words are links', () {
    test('a web address is, without the full stop that ends its sentence',
        () {
      expect(linkOfToken('https://example.org/tides'),
          'https://example.org/tides');
      expect(linkOfToken('https://example.org/tides.'),
          'https://example.org/tides');
      expect(linkOfToken('HTTP://Example.org/a?b=1),'),
          'HTTP://Example.org/a?b=1');
    });

    test('ordinary words, and an address with no site, are not', () {
      expect(linkOfToken('harbour'), isNull);
      expect(linkOfToken('example.org/tides'), isNull);
      expect(linkOfToken('https://'), isNull);
      expect(linkOfToken('(https://example.org)'), isNull);
    });
  });

  group('in the reader', () {
    late AppDatabase db;
    late int profileId;
    late int workId;
    late List<Uri> opened;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      profileId = await db.profilesDao.create('Ada');
      workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'note',
          title: 'Tide notes',
          persistence: 'work',
          firstSeenEpochDay: 100,
          lang: 'en');
      await db.spineDao.insertSegments(workId, const [
        (
          idx: 0,
          kind: 'prose',
          text: 'See the tide tables https://example.org/tides today.'
        ),
      ]);
      await db.profilesDao.updateReaderPrefs(profileId,
          (p) => p.copyWith(session: const ReaderSession(mode: 'scroll')));
      opened = [];
    });
    tearDown(() => db.close());

    Future<void> pumpReader(WidgetTester tester) async {
      final work = (await db.spineDao.workById(workId))!;
      await tester.pumpWidget(MaterialApp(
          home: ReaderScreen(
              db: db,
              profileId: profileId,
              work: work,
              openLink: (uri) async => opened.add(uri))));
      await tester.pumpAndSettle();
    }

    testWidgets('a link is shown shortened and underlined', (tester) async {
      await pumpReader(tester);

      final link = tester.widget<Text>(find.text('example.org/tides'));
      expect(link.style?.decoration, TextDecoration.underline);
      final plain = tester.widget<Text>(find.text('tables'));
      expect(plain.style?.decoration, isNot(TextDecoration.underline));
    });

    testWidgets('a tap on it asks where it goes, and Open opens it',
        (tester) async {
      await pumpReader(tester);

      await tester.tap(find.text('example.org/tides'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('link-confirm')), findsOneWidget);
      expect(find.text('example.org'), findsOneWidget);
      expect(opened, isEmpty, reason: 'nothing leaves before the yes');

      await tester.tap(find.byKey(const Key('link-open')));
      await tester.pumpAndSettle();
      expect(opened, [Uri.parse('https://example.org/tides')]);
    });

    testWidgets('Cancel opens nothing, and a tap on an ordinary word asks '
        'nothing', (tester) async {
      await pumpReader(tester);

      await tester.tap(find.text('example.org/tides'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('link-cancel')));
      await tester.pumpAndSettle();
      expect(opened, isEmpty);

      await tester.tap(find.text('tables'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('link-confirm')), findsNothing);
    });
  });
}
