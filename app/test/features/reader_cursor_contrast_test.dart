import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhearth_design/openhearth_design.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/reader/reader_prefs.dart';
import 'package:trellis/features/reader/reader_screen.dart';

import '../support/fake_player.dart';

/// 1.5.9 review (Task 11, I1): the cursor word lost its bold so a step
/// never reflows the line, and the pale band left in its place barely
/// showed on the current paragraph's tint; under Translation only it
/// matched the lit sentence around it. The cue stays width-neutral (a
/// painted band and a text colour, no weight or padding) but must stand
/// out: at least 3:1 against the paragraph tint and against the lit
/// sentence (WCAG 1.4.11 non-text contrast), with its word still
/// readable on it (4.5:1), in the light and dark themes the app ships.
void main() {
  double contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  for (final (name, theme) in [
    ('light', OhTheme.light()),
    ('dark', OhTheme.hearthDark()),
  ]) {
    testWidgets('$name: the cursor word stands out in a lit sentence',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final fakePlayer = FakeEpisodePlayer();
      final profileId = await db.profilesDao.create('Ada');
      final controller = PlayerController(
          db: db, profileId: profileId, createPlayer: () => fakePlayer);
      addTearDown(() async {
        controller.dispose();
        await db.close();
      });
      final workId = await db.spineDao.insertWork(
          profileId: profileId,
          kind: 'episode',
          title: 'Cursor',
          persistence: 'work',
          firstSeenEpochDay: 100,
          lang: 'en',
          sourceUrl: 'https://cast.test/cursor.mp3');
      await db.spineDao.insertSegments(workId, const [
        (
          idx: 0,
          kind: 'prose',
          text: 'Miss Brooke had that kind of beauty. Her hand was fine.'
        ),
      ]);
      await db.spineDao.insertAlignments(workId,
          const [(segmentIdx: 0, tStartMs: 0, tEndMs: 10000)]);
      for (final (i, src, body) in const [
        (0, 'Miss Brooke had that kind of beauty.',
            'La señorita Brooke tenía esa clase de belleza.'),
        (1, 'Her hand was fine.', 'Su mano era fina.'),
      ]) {
        await db.spineDao.upsertTranslationSentence(
            workId: workId,
            segmentIdx: 0,
            sentenceIdx: i,
            lang: 'es',
            sourceText: src,
            body: body);
      }
      await db.spineDao.setActiveTranslationLang(workId, 'es');
      await db.spineDao.setShowTranslationLayer(workId, true);
      await db.spineDao.setTranslationOnly(workId, true);
      await db.profilesDao.updateReaderPrefs(profileId,
          (p) => p.copyWith(session: const ReaderSession(mode: 'scroll')));

      await tester.pumpWidget(MaterialApp(
          theme: theme,
          home: ReaderScreen(
              db: db,
              profileId: profileId,
              work: (await db.spineDao.workById(workId))!,
              player: controller)));
      await tester.pumpAndSettle();
      await controller.playWork((await db.spineDao.workById(workId))!);
      await tester.pumpAndSettle();
      fakePlayer.emitPosition(const Duration(seconds: 7));
      await tester.pump();

      final cursor = find.byKey(const Key('cursor-word'));
      expect(cursor, findsOneWidget);
      expect(find.byKey(const Key('sentence-lit')), findsWidgets);

      WordBandPainter bandOf(Finder f) =>
          tester.widget<CustomPaint>(f).painter! as WordBandPainter;
      final cursorBand = bandOf(find
          .ancestor(of: cursor, matching: find.byType(CustomPaint))
          .first);
      final litBand = bandOf(find.byKey(const Key('sentence-lit')).first);
      final tint =
          tester.widget<Container>(find.byKey(const Key('segment-tile-0')))
              .color!;
      final ink = tester.widget<Text>(cursor).style!.color!;

      final vsTint = contrast(cursorBand.color, tint);
      final vsLit = contrast(cursorBand.color, litBand.color);
      final text = contrast(ink, cursorBand.color);
      // ignore: avoid_print
      print('$name: cursor band vs paragraph tint ${vsTint.toStringAsFixed(2)}'
          ', vs lit sentence ${vsLit.toStringAsFixed(2)}'
          ', word on band ${text.toStringAsFixed(2)}');
      expect(vsTint, greaterThanOrEqualTo(3));
      expect(vsLit, greaterThanOrEqualTo(3));
      expect(text, greaterThanOrEqualTo(4.5));
    });
  }
}
