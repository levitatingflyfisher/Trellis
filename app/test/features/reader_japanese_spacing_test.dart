import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_prefs.dart';
import 'package:trellis/features/reader/reader_screen.dart';

/// Japanese on the scrolling page (board-0126 point 2): the tokenizer
/// splits Japanese into one unit per character so each can be lit and
/// tapped, and the page set those units a space apart, 今 日 は 晴 れ.
/// Characters that touch in the text touch on the page; Latin words keep
/// their space, inside Japanese too; lighting and tapping still work one
/// character at a time.
void main() {
  late AppDatabase db;
  late int profileId;
  late int workId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'article',
        title: '天気',
        persistence: 'work',
        firstSeenEpochDay: 100,
        lang: 'ja');
    await db.spineDao.insertSegments(workId, const [
      (idx: 0, kind: 'prose', text: '今日は晴れです。称号を MWP に変えた。'),
    ]);
  });
  tearDown(() => db.close());

  Future<void> open(WidgetTester tester) async {
    await db.profilesDao.updateReaderPrefs(
        profileId, (p) => p.copyWith(session: ReaderSession(mode: 'scroll')));
    final work = (await db.spineDao.workById(workId))!;
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(db: db, profileId: profileId, work: work)));
    await tester.pumpAndSettle();
  }

  Rect rectOf(WidgetTester tester, String unit) =>
      tester.getRect(find.text(unit).first);

  testWidgets('characters that touch in the text touch on the page',
      (tester) async {
    await open(tester);
    for (final (a, b) in [('日', 'は'), ('晴', 'れ'), ('れ', 'で')]) {
      expect(rectOf(tester, b).left - rectOf(tester, a).right,
          closeTo(0, 0.5),
          reason: '$a and $b sit together');
    }
  });

  testWidgets('a Latin word inside Japanese keeps its space', (tester) async {
    await open(tester);
    expect(rectOf(tester, 'MWP').left - rectOf(tester, 'を').right,
        greaterThan(2));
  });

  testWidgets('a tapped character is the one lit, and lighting moves no '
      'character', (tester) async {
    await open(tester);
    final before = rectOf(tester, '晴').topLeft;
    await tester.tap(find.text('晴'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const Key('cursor-word'))).data,
        '晴');
    expect(rectOf(tester, '晴').topLeft, before);
    await tester.tap(find.text('れ'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const Key('cursor-word'))).data,
        'れ');
    expect(rectOf(tester, '晴').topLeft, before);
  });
}
