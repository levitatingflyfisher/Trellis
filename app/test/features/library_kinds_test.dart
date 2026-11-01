import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart' hide Alignment;
import 'package:trellis/main.dart';
import '../support/pick_reader.dart';
import '../support/tabs.dart';

/// Owner, 12 Nov: "what is library if 'latest' has all, text, and audio?"
/// Lead's ruling: Latest is what arrives from your shows, newest first;
/// the Library is what you keep. One line under each title says so, and
/// the Library's chips are its own kinds.
void main() {
  late AppDatabase db;
  late int profileId;
  late int feedId;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    feedId = await db.feedsDao
        .insertFeed(profileId: profileId, url: 'https://c.test/f', title: 'Coast');
  });
  tearDown(() => db.close());

  Future<int> work(String kind, String title) => db.spineDao.insertWork(
      profileId: profileId,
      kind: kind,
      title: title,
      persistence: 'work',
      firstSeenEpochDay: 100);

  Future<int> episode(String title, {String? guid}) async {
    final id = await work('episode', title);
    await db.feedsDao.insertEpisode(
        workId: id,
        feedId: feedId,
        guid: guid ?? title,
        enclosureUrl: 'https://c.test/$id.mp3',
        publishedAtMs: id);
    return id;
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(TrellisApp(db: db));
    await tester.pumpAndSettle();
    await pickReader(tester, 'Ada');
  }

  testWidgets('one plain line under each title says what the screen is for',
      (tester) async {
    await work('book', 'A book');
    await pumpApp(tester);
    expect(
        tester.widget<Text>(find.byKey(const Key('latest-purpose'))).data,
        'What arrives from your shows, newest first.');
    await toTab(tester, 'Library');
    expect(
        tester.widget<Text>(find.byKey(const Key('library-purpose'))).data,
        'What you keep: books, articles, texts, and episodes you kept or '
        'made.');
  });

  testWidgets('the Library’s chips are its own kinds, only those it holds, '
      'and each shows that kind alone', (tester) async {
    await work('book', 'A book');
    await work('note', 'A pasted text');
    await work('audiobook', 'An audiobook');
    final kept = await episode('A kept episode');
    await episode('A kept episode (Spanish)', guid: 'spoken:$kept:es');
    await pumpApp(tester);
    await toTab(tester, 'Library');

    final chips = [
      for (final c in tester.widgetList<ChoiceChip>(find.byWidgetPredicate(
          (w) => w is ChoiceChip && '${w.key}'.contains('library-kind-'))))
        (c.label as Text).data,
    ];
    expect(chips,
        ['All', 'Books', 'Texts', 'Audiobooks', 'Episodes', 'Made episodes']);

    Future<void> chip(String kind) async {
      await tester.tap(find.byKey(Key('library-kind-$kind')));
      await tester.pumpAndSettle();
    }

    await chip('audiobook');
    expect(find.text('An audiobook'), findsOneWidget);
    expect(find.text('A book'), findsNothing);

    await chip('note');
    expect(find.text('A pasted text'), findsOneWidget);
    expect(find.text('An audiobook'), findsNothing);

    await chip('made');
    expect(find.text('A kept episode (Spanish)'), findsOneWidget);
    expect(find.text('A kept episode'), findsNothing);

    await chip('episode');
    expect(find.text('A kept episode'), findsOneWidget);
    expect(find.text('A kept episode (Spanish)'), findsNothing);

    await chip('all');
    // Newest first: the made episode and the kept one lead the list.
    expect(find.text('A kept episode (Spanish)'), findsOneWidget);
    expect(find.text('A kept episode'), findsOneWidget);
  });

  testWidgets('at 320 dp and large text every chip is on screen',
      (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await work('book', 'A book');
    await work('note', 'A pasted text');
    await work('article', 'An article');
    await work('audiobook', 'An audiobook');
    final kept = await episode('A kept episode');
    await episode('A kept episode (Spanish)', guid: 'spoken:$kept:es');
    await pumpApp(tester);
    await toTab(tester, 'Library');
    for (final kind in ['all', 'book', 'article', 'note', 'audiobook',
        'episode', 'made']) {
      final r = tester.getRect(find.byKey(Key('library-kind-$kind')));
      expect(r.right, lessThanOrEqualTo(320), reason: kind);
    }
    expect(tester.takeException(), isNull);
  });
}
