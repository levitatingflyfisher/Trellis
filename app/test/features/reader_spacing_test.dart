import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/reader/reader_prefs.dart';
import 'package:trellis/features/reader/reader_screen.dart';

import '../support/fake_player.dart';

/// 1.5.9 (user: "the reading layout spacing is horrible on both windows
/// (well the line one is okay)"): Page > Follow along, in Both and in
/// Translation only, sets its text to Line's rhythm. Lines step by the
/// line height alone, words sit a plain space apart, and lighting a word
/// or a sentence never pushes the words around it. In Both, a
/// translation sits close under its own sentence and the next pair
/// stands clear of it. All of it holds at text scale 2.0 on a phone.
void main() {
  late AppDatabase db;
  late FakeEpisodePlayer fakePlayer;
  late PlayerController controller;
  late int profileId;
  late int workId;

  const para0 = 'Miss Brooke had that kind of beauty which seems to be '
      'thrown into relief by poor dress. Her hand and wrist were so finely '
      'formed that she could wear sleeves not less bare of style.';
  const para1 = 'She was usually spoken of as being remarkably clever. '
      'Celia wore scarcely more trimmings.';

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    fakePlayer = FakeEpisodePlayer();
    profileId = await db.profilesDao.create('Ada');
    controller = PlayerController(
        db: db, profileId: profileId, createPlayer: () => fakePlayer);
    workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: 'Spacing',
        persistence: 'work',
        firstSeenEpochDay: 100,
        lang: 'en',
        sourceUrl: 'https://cast.test/spacing.mp3');
    await db.spineDao.insertSegments(workId, const [
      (idx: 0, kind: 'prose', text: para0),
      (idx: 1, kind: 'prose', text: para1),
    ]);
    await db.spineDao.insertAlignments(workId, const [
      (segmentIdx: 0, tStartMs: 0, tEndMs: 10000),
      (segmentIdx: 1, tStartMs: 10000, tEndMs: 20000),
    ]);
    for (final (seg, i, src, body) in const [
      (
        0,
        0,
        'Miss Brooke had that kind of beauty which seems to be thrown into '
            'relief by poor dress.',
        'La señorita Brooke tenía esa clase de belleza que un vestido '
            'pobre realza.'
      ),
      (
        0,
        1,
        'Her hand and wrist were so finely formed that she could wear '
            'sleeves not less bare of style.',
        'Sus manos eran tan finas que podía llevar mangas sencillas.'
      ),
      (
        1,
        0,
        'She was usually spoken of as being remarkably clever.',
        'Solía decirse de ella que era muy lista.'
      ),
      (
        1,
        1,
        'Celia wore scarcely more trimmings.',
        'Celia apenas llevaba más adornos.'
      ),
    ]) {
      await db.spineDao.upsertTranslationSentence(
          workId: workId,
          segmentIdx: seg,
          sentenceIdx: i,
          lang: 'es',
          sourceText: src,
          body: body);
    }
    await db.spineDao.setActiveTranslationLang(workId, 'es');
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
  });

  void phone(WidgetTester tester, {double scale = 1.0}) {
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    tester.view.devicePixelRatio = 2.625;
    tester.view.physicalSize = const Size(412 * 2.625, 915 * 2.625);
    tester.platformDispatcher.textScaleFactorTestValue = scale;
  }

  Future<void> open(WidgetTester tester, String mode,
      {String display = 'plain'}) async {
    await db.spineDao.setShowTranslationLayer(workId, display != 'plain');
    await db.spineDao.setTranslationOnly(workId, display == 'only');
    await db.profilesDao.updateReaderPrefs(
        profileId, (p) => p.copyWith(session: ReaderSession(mode: mode)));
    final work = (await db.spineDao.workById(workId))!;
    await tester.pumpWidget(MaterialApp(
        home: ReaderScreen(
            db: db, profileId: profileId, work: work, player: controller)));
    await tester.pumpAndSettle();
  }

  /// Every flowing word of segment 0's tile, top-left and size, in order.
  List<Rect> wordRects(WidgetTester tester) => [
        for (final e in find
            .descendant(
                of: find.byKey(const Key('segment-tile-0')),
                matching: find.byType(Text))
            .evaluate())
          if ((e.widget as Text).data != null)
            (e.renderObject! as RenderBox).localToGlobal(Offset.zero) &
                (e.renderObject! as RenderBox).size
      ];

  double bodySize(WidgetTester tester) => Theme.of(
          tester.element(find.byKey(const Key('segment-tile-0'))))
      .textTheme
      .bodyLarge!
      .fontSize!;

  /// The distinct line tops of segment 0's words below its first line
  /// (the drop cap, when the work opens on it, stands taller than the
  /// rest of its run).
  List<double> lineTops(WidgetTester tester) {
    final rects = wordRects(tester);
    final firstRunBottom = rects.first.bottom;
    final tops = <double>[];
    for (final r in rects) {
      if (r.bottom <= firstRunBottom + 0.5) continue;
      if (tops.isEmpty || (r.top - tops.last).abs() > 0.5) tops.add(r.top);
    }
    return tops;
  }

  for (final display in ['plain', 'only']) {
    testWidgets('Follow along ($display): lines step by the line height '
        'alone, as on Line', (tester) async {
      phone(tester);
      await open(tester, 'scroll', display: display);
      final tops = lineTops(tester);
      expect(tops.length, greaterThan(2));
      final pitch = bodySize(tester) * 1.6;
      for (var i = 1; i < tops.length; i++) {
        expect(tops[i] - tops[i - 1], closeTo(pitch, 0.5),
            reason: 'no run spacing on top of the line height');
      }
    });
  }

  testWidgets('Follow along: words sit a plain space apart, at any text '
      'scale', (tester) async {
    phone(tester, scale: 1.5);
    await open(tester, 'scroll');
    final word = tester.widget<Text>(find.text('Brooke'));
    final space = (TextPainter(
            text: TextSpan(text: 'a a', style: word.style),
            textDirection: TextDirection.ltr,
            textScaler: const TextScaler.linear(1.5))
          ..layout())
        .width -
        (TextPainter(
                text: TextSpan(text: 'aa', style: word.style),
                textDirection: TextDirection.ltr,
                textScaler: const TextScaler.linear(1.5))
              ..layout())
            .width;
    final a = tester.getRect(find.text('Brooke'));
    final b = tester.getRect(find.text('had'));
    expect(b.left - a.right, closeTo(space, 0.5));
  });

  testWidgets('Follow along: lighting the next word moves no word',
      (tester) async {
    phone(tester);
    await open(tester, 'scroll');
    final before = wordRects(tester);
    await tester.tap(find.text('kind'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const Key('cursor-word'))).data,
        'kind');
    await tester.tap(find.text('beauty'));
    await tester.pumpAndSettle();
    final after = wordRects(tester);
    expect([for (final r in after) r.topLeft],
        [for (final r in before) r.topLeft]);
  });

  testWidgets('Translation only: lighting the heard sentence moves no word',
      (tester) async {
    phone(tester);
    await db.spineDao.setShowTranslationLayer(workId, true);
    await db.spineDao.setTranslationOnly(workId, true);
    await open(tester, 'scroll', display: 'only');
    final before = wordRects(tester);
    await controller.playWork((await db.spineDao.workById(workId))!);
    await tester.pumpAndSettle();
    fakePlayer.emitPosition(const Duration(seconds: 7));
    await tester.pump();
    expect(find.byKey(const Key('sentence-lit')), findsWidgets);
    final after = wordRects(tester);
    expect([for (final r in after) r.topLeft],
        [for (final r in before) r.topLeft]);
  });

  for (final mode in ['scroll', 'lines']) {
    testWidgets('Both ($mode): a translation sits close under its sentence, '
        'and the next pair stands clear', (tester) async {
      phone(tester);
      await open(tester, mode, display: 'both');
      final t0 = tester.getRect(find.byKey(const Key('translation-0-0')));
      final t1 = tester.getRect(find.byKey(const Key('translation-0-1')));
      final tile = find.byKey(const Key('segment-tile-0'));
      // Sentence 0 ends at "dress."; sentence 1 begins at "Her".
      double bottomOf(String w) => mode == 'scroll'
          ? tester.getRect(find.text(w)).bottom
          : tester
              .getRect(find
                  .descendant(of: tile, matching: find.byType(RichText))
                  .first)
              .bottom;
      double topOfSecond() => mode == 'scroll'
          ? tester.getRect(find.text('Her')).top
          : tester
              .getRect(find
                  .descendant(of: tile, matching: find.byType(RichText))
                  .at(2))
              .top;
      expect(t0.top - bottomOf('dress.'), closeTo(kTranslationGapAbove, 0.5));
      expect(topOfSecond() - t0.bottom, closeTo(kTranslationGapBelow, 0.5));
      expect(t1.top, greaterThan(t0.bottom));
      // The paragraph's last translation leaves the gap below to the
      // paragraph spacing alone: no doubled gap before the next one.
      expect(tester.getRect(tile).bottom - t1.bottom, 8 + 8);
      final style = tester
          .widget<Text>(find.byKey(const Key('translation-0-0')))
          .style!;
      expect(style.height, kTranslationLineHeight);
    });
  }

  test('the spacing values', () {
    // Tight enough to read as one pair, clearly less than the gap to the
    // next pair, which is itself less than a paragraph's.
    expect(kTranslationGapAbove, 4);
    expect(kTranslationGapBelow, 12);
    expect(kTranslationLineHeight, 1.5);
    expect(const ReaderTypography().paragraphSpacing, 8);
    expect(const ReaderTypography().lineHeight, 1.6);
  });

  for (final mode in ['words', 'scroll', 'lines']) {
    for (final display in ['plain', 'both', 'only']) {
      testWidgets('no overflow at text scale 2.0: $mode, $display',
          (tester) async {
        phone(tester, scale: 2.0);
        await open(tester, mode, display: display);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
