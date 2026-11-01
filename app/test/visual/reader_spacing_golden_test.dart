import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loom_core/loom_core.dart' as core;
import 'package:openhearth_design/openhearth_design.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/reader/reader_prefs.dart';
import 'package:trellis/features/reader/reader_screen.dart';

import '../support/fake_player.dart';

/// The visual-loop check for 1.5.9's reading spacing (not a regression
/// gate; reader_spacing_test.dart pins the values): every reading mode,
/// for an article and a transcript, untranslated, in Both and in
/// Translation only, at Pixel 6a size. The PNGs are gitignored.
/// Regenerate and inspect with:
///   VISUAL_TOUR=1 flutter test test/visual/reader_spacing_golden_test.dart --update-goldens
void main() {
  final touring = Platform.environment['VISUAL_TOUR'] == '1';

  const article = [
    'Miss Brooke had that kind of beauty which seems to be thrown into '
        'relief by poor dress. Her hand and wrist were so finely formed '
        'that she could wear sleeves not less bare of style than those '
        'in which the Blessed Virgin appeared to Italian painters.',
    'She was usually spoken of as being remarkably clever, but with the '
        'addition that her sister Celia had more common sense. Nevertheless, '
        'Celia wore scarcely more trimmings.',
    'Early in the day a small party set out for the village. The road '
        'was long and the weather uncertain.',
  ];
  // Spanish, not Russian: the bundled Lora has no Cyrillic, and a test
  // has no system fallback font, so Russian would draw as boxes. The
  // spacing under test is the same in either language.
  const articleEs = [
    [
      'La señorita Brooke tenía esa clase de belleza que un vestido '
          'pobre realza.',
      'Sus manos y muñecas eran tan finas que podía llevar mangas tan '
          'sencillas como las de la Virgen en los cuadros italianos.',
    ],
    [
      'Solía decirse de ella que era muy lista, pero se añadía que su '
          'hermana Celia tenía más sentido común.',
      'Aun así, Celia apenas llevaba más adornos.',
    ],
    [
      'Temprano, un pequeño grupo salió hacia el pueblo.',
      'El camino era largo y el tiempo incierto.',
    ],
  ];
  const transcript = [
    'So welcome back to the show. Today we are talking about the aurora, '
        'and why it reached so far south this year.',
    'Right, and the short answer is the solar cycle. We are near the '
        'maximum, so there are more flares and more storms.',
    'And a storm is what pushes the oval toward the equator. That is the '
        'part people can actually see from their gardens.',
  ];
  const transcriptEs = [
    [
      'Bienvenidos de nuevo al programa.',
      'Hoy hablamos de la aurora y de por qué este año llegó tan al sur.',
    ],
    [
      'Sí, y la respuesta corta es el ciclo solar.',
      'Estamos cerca del máximo, así que hay más erupciones y más '
          'tormentas.',
    ],
    [
      'Y una tormenta es lo que empuja el óvalo hacia el ecuador.',
      'Esa es la parte que la gente puede ver desde su jardín.',
    ],
  ];

  testWidgets('reader spacing: every mode, phone width', skip: !touring,
      (tester) async {
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    // Pixel 6a: 1080×2400 px at 2.625.
    tester.view.devicePixelRatio = 2.625;
    tester.view.physicalSize = const Size(1080, 2400);

    for (final kind in ['article', 'transcript']) {
      for (final display in ['plain', 'both', 'only']) {
        for (final mode in ['words', 'scroll', 'lines']) {
          for (final scale in [1.0, 2.0]) {
            if (scale != 1.0 && display != 'both') continue;
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            final db = AppDatabase.forTesting(NativeDatabase.memory());
            final profileId = await db.profilesDao.create('Ada');
            final isEp = kind == 'transcript';
            final workId = await db.spineDao.insertWork(
                profileId: profileId,
                kind: isEp ? 'episode' : 'article',
                title: isEp ? 'Aurora season' : 'Middlemarch, chapter 1',
                persistence: 'work',
                firstSeenEpochDay: 100,
                lang: 'en',
                sourceUrl: isEp ? 'https://cast.test/1.mp3' : null);
            final paras = isEp ? transcript : article;
            final es = isEp ? transcriptEs : articleEs;
            await db.spineDao.insertSegments(workId, [
              for (var i = 0; i < paras.length; i++)
                (idx: i, kind: 'prose', text: paras[i]),
            ]);
            if (isEp) {
              await db.spineDao.insertAlignments(workId, [
                for (var i = 0; i < paras.length; i++)
                  (segmentIdx: i, tStartMs: i * 20000, tEndMs: (i + 1) * 20000)
              ]);
            }
            if (display != 'plain') {
              for (var s = 0; s < paras.length; s++) {
                final sentences = [
                  for (final x in core.splitSentences(paras[s])) x.text
                ];
                for (var k = 0; k < sentences.length; k++) {
                  await db.spineDao.upsertTranslationSentence(
                      workId: workId,
                      segmentIdx: s,
                      sentenceIdx: k,
                      lang: 'es',
                      sourceText: sentences[k],
                      body: es[s][k]);
                }
              }
              await db.spineDao.setActiveTranslationLang(workId, 'es');
              await db.spineDao.setShowTranslationLayer(workId, true);
              await db.spineDao.setTranslationOnly(workId, display == 'only');
            }
            await db.profilesDao.updateReaderPrefs(profileId,
                (p) => p.copyWith(session: ReaderSession(mode: mode)));
            // The cursor a few words into the second paragraph, so the
            // current word and paragraph show as they do mid-read.
            await db.spineDao.savePosition(
                profileId: profileId,
                workId: workId,
                segmentIdx: 1,
                wordIdx: 4,
                lastModality: 'read');
            final work = (await db.spineDao.workById(workId))!;
            await tester.pumpWidget(MaterialApp(
                theme: OhTheme.light(),
                home: ReaderScreen(
                    key: ValueKey('$kind$display$mode$scale'),
                    db: db,
                    profileId: profileId,
                    work: work)));
            await tester.pumpAndSettle();
            final tag = scale == 1.0 ? '' : '_x2';
            await expectLater(find.byType(ReaderScreen),
                matchesGoldenFile(
                    'goldens/reader_spacing/${kind}_${display}_$mode$tag.png'));
            await tester.pumpWidget(const SizedBox());
            await tester.pumpAndSettle();
            await db.close();
          }
        }
      }
    }
  });

  // The cursor word inside the sentence lit while following audio under
  // Translation only (the review of 1.5.9's spacing: the two shared a
  // colour), in both themes the app ships.
  for (final (name, theme) in [
    ('light', OhTheme.light()),
    ('dark', OhTheme.hearthDark()),
  ]) {
    testWidgets('reader cursor in a lit sentence: $name', skip: !touring,
        (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 2.625;
      tester.view.physicalSize = const Size(1080, 2400);
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
          title: 'Aurora season',
          persistence: 'work',
          firstSeenEpochDay: 100,
          lang: 'en',
          sourceUrl: 'https://cast.test/1.mp3');
      await db.spineDao.insertSegments(workId, [
        for (var i = 0; i < transcript.length; i++)
          (idx: i, kind: 'prose', text: transcript[i]),
      ]);
      await db.spineDao.insertAlignments(workId, [
        for (var i = 0; i < transcript.length; i++)
          (segmentIdx: i, tStartMs: i * 20000, tEndMs: (i + 1) * 20000)
      ]);
      for (var s = 0; s < transcript.length; s++) {
        final sentences = [
          for (final x in core.splitSentences(transcript[s])) x.text
        ];
        for (var k = 0; k < sentences.length; k++) {
          await db.spineDao.upsertTranslationSentence(
              workId: workId,
              segmentIdx: s,
              sentenceIdx: k,
              lang: 'es',
              sourceText: sentences[k],
              body: transcriptEs[s][k]);
        }
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
      // Late in the second paragraph: its second sentence lights.
      fakePlayer.emitPosition(const Duration(seconds: 34));
      await tester.pumpAndSettle();
      await expectLater(find.byType(ReaderScreen),
          matchesGoldenFile('goldens/reader_spacing/cursor_$name.png'));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }
}
