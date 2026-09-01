import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/scripted_fetcher.dart';
import '../support/pick_reader.dart';

/// Fleet ruling on top bars: icon plus a short visible label; rare actions
/// in a worded menu; a tooltip is never a command's only name (audit rank
/// 3). Checked where the ruling bites: a 360 dp phone at 1.3x text, and
/// no overflow at 320 dp x 3.0.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> pumpAt(WidgetTester tester, Size size, double scale) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    final id = await db.profilesDao.create('Adalheidis Winterbourne');
    final work = await db.spineDao.insertWork(
        profileId: id,
        kind: 'note',
        title: 'A Rather Longer Title Than Any Bar Would Prefer',
        persistence: 'work',
        firstSeenEpochDay: 100);
    await db.spineDao.insertSegments(
        work, const [(idx: 0, kind: 'prose', text: 'One two three.')]);
    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((u, h) => textResponse('')),
        createPlayer: () => FakeEpisodePlayer()));
    await tester.pumpAndSettle();
    await pickReader(tester, 'Adalheidis Winterbourne');
  }

  Future<void> toTab(WidgetTester tester, String tab) async {
    await tester.tap(find.descendant(
        of: find.byType(NavigationBar), matching: find.text(tab)));
    await tester.pumpAndSettle();
  }

  void seen(String label) => expect(
      find.descendant(of: find.byType(AppBar), matching: find.text(label)),
      findsOneWidget,
      reason: '"$label" must be readable on the bar, not only a tooltip');

  /// openhearth_design 0.9 folds bar words by space: a word stays while it
  /// fits beside a whole title, and folds (rightmost first) into its
  /// tooltip when it does not. So on a tab bar: the title is whole, every
  /// command is named (by its word, or folded by its tooltip), and a
  /// visible word never sits right of a folded one.
  void barHolds(WidgetTester tester, String title,
      List<(String word, String tooltip)> commands) {
    final t = tester.renderObject<RenderParagraph>(find.descendant(
        of: find.byType(AppBar), matching: find.text(title)));
    expect(t.didExceedMaxLines, isFalse, reason: '"$title" is cut off');
    final shown = <bool>[];
    for (final (word, tip) in commands) {
      final visible = find
          .descendant(of: find.byType(AppBar), matching: find.text(word))
          .evaluate()
          .isNotEmpty;
      if (!visible) {
        expect(find.byTooltip(tip), findsWidgets,
            reason: '"$word" is neither on the bar nor in a tooltip');
      }
      shown.add(visible);
    }
    for (var i = 1; i < shown.length; i++) {
      if (shown[i]) expect(shown[i - 1], isTrue, reason: 'fold order');
    }
  }

  const theme = ('Auto', 'Theme: Follow phone');
  const more = ('More', 'More');

  testWidgets('360 dp at 1.3x: every tab bar and the reader name their '
      'commands', (tester) async {
    await pumpAt(tester, const Size(360, 780), 1.3);
    seen('Filter');
    barHolds(tester, 'Library', [('Filter', 'Filter'), theme, more]);
    await toTab(tester, 'Inbox');
    seen('Feeds');
    barHolds(tester, 'Inbox', [('Feeds', 'Feeds'), theme, more]);
    await toTab(tester, 'Courses');
    seen('Backup');
    await toTab(tester, 'Library');
    await tester.tap(find.text('A Rather Longer Title Than Any Bar Would Prefer'));
    await tester.pumpAndSettle();
    // The reader's title (a book's name) cannot be whole beside its
    // commands, so the bar keeps it a floor and folds right to left.
    final shown = [
      for (final w in ['Words', 'Read aloud', 'More'])
        find
            .descendant(of: find.byType(AppBar), matching: find.text(w))
            .evaluate()
            .isNotEmpty,
    ];
    // At 1.3x the back button, three controls and a 30% title floor do not
    // fit worded on a 360 dp phone, so the reader bar may fold them all.
    // Each keeps its name: the mode picker in its tooltip, Read aloud and
    // More in theirs.
    if (!shown.first) {
      expect(find.byTooltip(RegExp(r'^Reading mode: ')), findsOneWidget);
    }
    for (var i = 1; i < shown.length; i++) {
      if (shown[i]) expect(shown[i - 1], isTrue, reason: 'fold order');
    }
    expect(find.byTooltip('Read aloud'), shown[1] ? findsNothing : findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('320 dp at 3.0x: the bars do not overflow and keep their '
      'titles whole', (tester) async {
    await pumpAt(tester, const Size(320, 640), 3.0);
    for (final tab in ['Inbox', 'Courses', 'Library']) {
      await toTab(tester, tab);
      expect(tester.takeException(), isNull, reason: tab);
    }
    // The house floor: titles stay whole at 320 x 3.0, commands named.
    await toTab(tester, 'Library');
    barHolds(tester, 'Library', [('Filter', 'Filter'), theme, more]);
    await toTab(tester, 'Inbox');
    barHolds(tester, 'Inbox', [('Feeds', 'Feeds'), theme, more]);
    await toTab(tester, 'Library');
    await tester.tap(find.text('A Rather Longer Title Than Any Bar Would Prefer'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'reader');
  });
}
