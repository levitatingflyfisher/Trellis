import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_screen.dart';
import 'dart:io';

/// Font-coverage verification for CJK text on the reader's own surfaces
/// (Campaign 8 "Babel widens" Phase 3): the app bundles only Lora and
/// Nunito (Latin/Cyrillic Google Fonts, no CJK glyphs — confirmed by their
/// absence from app/pubspec.yaml's font declarations and the ~200KB size
/// of each .ttf, nowhere near the multi-MB a CJK glyph set requires). This
/// does not by itself say whether CJK text renders legibly or as tofu —
/// Flutter falls back to a system font for glyphs missing from the
/// requested family, so the real answer depends on the render pipeline,
/// not just the bundle manifest. Rendered and READ (Read tool, not
/// pixel-diffed — same self-guarded VISUAL_TOUR=1 convention as
/// tour_golden_test.dart) to get an honest answer instead of assuming one
/// either way.
///
/// THE FIRST GOLDEN'S FINDING IS WHY en-zh IS NOT A SHIPPED TRANSLATION
/// PAIR (registry.dart's own comment has the full reasoning): both
/// surfaces rendered tofu, `fontFamilyFallback` naming an installed
/// system font made no difference (the `flutter test` golden pipeline
/// never consults fontconfig — proven separately, not assumed), and
/// bundling a CJK subset font to close the gap the honest way (measured:
/// Noto Sans SC's single-weight/single-region subset OTF, 8,331,336
/// bytes) does not fit `app/budgets.json`'s C3 headroom. zh-en (Chinese
/// source -> English output) is unaffected and stays shipped — its
/// output is Latin text. The second golden (a native Japanese import)
/// documents the SAME ceiling for a different real use case: reading a
/// CJK-sourced work has nothing to do with which MT pairs ship.
void main() {
  final touring = Platform.environment['VISUAL_TOUR'] == '1';

  testWidgets(
      'reader scroll mode: a Chinese translation layer over an English '
      'work — NOT shipped as a real feature (see the library doc comment '
      'above); this render is the evidence that led to that call, kept '
      'as a regression guard against ever shipping it un-verified',
      skip: !touring, (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final profileId = await db.profilesDao.create('Ada');
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'article',
        title: 'A Story',
        persistence: 'work',
        firstSeenEpochDay: 100,
        lang: 'en');
    await db.spineDao.insertSegments(workId, const [
      (
        idx: 0,
        kind: 'prose',
        text: 'The old house stood quietly at the end of the lane.'
      ),
    ]);
    await db.spineDao.upsertTranslationSentence(
        workId: workId,
        segmentIdx: 0,
        sentenceIdx: 0,
        lang: 'zh',
        sourceText: 'The old house stood quietly at the end of the lane.',
        body: '那座老房子静静地矗立在小巷的尽头。');
    await db.spineDao.setActiveTranslationLang(workId, 'zh');
    final work =
        (await db.spineDao.worksOf(profileId)).firstWhere((w) => w.id == workId);

    await tester.pumpWidget(
        MaterialApp(home: ReaderScreen(db: db, profileId: profileId, work: work)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mode-toggle'))); // scroll mode
    await tester.pumpAndSettle();

    await expectLater(find.byType(ReaderScreen),
        matchesGoldenFile('goldens/cjk_scroll_translation.png'));
  });

  testWidgets(
      'reader RSVP mode: a native Japanese-sourced work, one segmented '
      'word at a time (exercises the Phase 3 tokenizer fix directly, not '
      'just a translation layer)', skip: !touring, (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final profileId = await db.profilesDao.create('Ada');
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'article',
        title: '古い家',
        persistence: 'work',
        firstSeenEpochDay: 100,
        lang: 'ja');
    await db.spineDao.insertSegments(workId, const [
      (idx: 0, kind: 'prose', text: '私はアメリカに行く。今日は天気がいいですね。'),
    ]);
    final work =
        (await db.spineDao.worksOf(profileId)).firstWhere((w) => w.id == workId);

    await tester.pumpWidget(
        MaterialApp(home: ReaderScreen(db: db, profileId: profileId, work: work)));
    await tester.pumpAndSettle();

    await expectLater(find.byType(ReaderScreen),
        matchesGoldenFile('goldens/cjk_rsvp_japanese.png'));
  });
}
