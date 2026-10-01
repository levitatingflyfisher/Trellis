import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhearth_design/openhearth_design.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/reader/reader_code_face.dart';
import 'package:trellis/main.dart';
import '../support/pick_reader.dart';

/// Code and table blocks keep their columns on the web. Without a bundled
/// monospace, OhTypography.code() is Nunito there (the self-hosted web
/// build has no platform monospace), and ASCII tables lose alignment.
void main() {
  group('readerCodeStyle', () {
    test('on the web it is the bundled mono, falling back to Nunito', () {
      final s = readerCodeStyle(web: true);
      expect(s.fontFamily, kReaderMonoFamily);
      expect(s.fontFamilyFallback, ['packages/openhearth_design/Nunito'],
          reason: 'a glyph the subset lacks must come from a bundled face, '
              'not a fallback font the web build would fetch and 404 on');
      expect(s.fontSize, 13);
      expect(s.height, 1.4);
    });

    test('no ambient package can re-prefix the family', () {
      // A theme style carrying a package, as the fleet's do.
      const ambient = TextStyle(
          fontFamily: 'Nunito', package: 'openhearth_design', fontSize: 16);
      for (final web in [true, false]) {
        final merged = ambient.merge(readerCodeStyle(web: web));
        expect(merged.fontFamily, web ? kReaderMonoFamily : 'monospace');
        if (web) {
          expect(merged.fontFamilyFallback,
              ['packages/openhearth_design/Nunito']);
        }
      }
    });

    test('natively it is the ladder code face (platform monospace)', () {
      expect(readerCodeStyle(web: false), OhTypography.code(web: false));
      expect(readerCodeStyle(web: false).inherit, isFalse,
          reason: 'openhearth_design 0.9.2 code() must not inherit, or the '
              'theme package prefixes monospace');
    });
  });

  testWidgets('the bundled mono really is fixed-width, box drawing included',
      (tester) async {
    final loader = FontLoader(kReaderMonoFamily)
      ..addFont(Future.value(ByteData.sublistView(
          File('assets/fonts/NotoSansMono-Subset.ttf').readAsBytesSync())));
    await loader.load();

    double width(String s) {
      final p = TextPainter(
        text: TextSpan(text: s, style: readerCodeStyle(web: true)),
        textDirection: TextDirection.ltr,
      )..layout();
      return p.width;
    }

    // 0.6 em per cell: Noto Sans Mono's advance. The test font draws every
    // glyph 1 em wide, so 5 × 13 × 0.6 cannot come from it by accident.
    const cell = 13 * 0.6;
    for (final s in ['iiiii', 'MMMMM', '|-+|.', '12.50', '┌─┬─┐', '├─┼─┤']) {
      expect(width(s), closeTo(5 * cell, 0.01), reason: s);
    }
  });

  testWidgets('the reader draws code and table blocks in readerCodeStyle',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final profileId = await db.profilesDao.create('Ada');
    final workId = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'note',
        title: 'Columns',
        persistence: 'work',
        firstSeenEpochDay: 100);
    await db.spineDao.insertSegments(workId, [
      (idx: 0, kind: 'prose', text: 'Before.'),
      (idx: 1, kind: 'table', text: '| a | b |\n|---|---|\n| 1 | 2 |'),
      (idx: 2, kind: 'code', text: 'x = 1\ny = 2\nz = 3'),
    ]);

    await tester.pumpWidget(TrellisApp(db: db));
    await tester.pumpAndSettle();
    await pickReader(tester, 'Ada');
    await tester.tap(find.text('Columns'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mode-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mode-item-scroll')));
    await tester.pumpAndSettle();

    final onSurface =
        Theme.of(tester.element(find.text('x = 1\ny = 2\nz = 3')))
            .colorScheme
            .onSurface;
    for (final t in ['| a | b |\n|---|---|\n| 1 | 2 |', 'x = 1\ny = 2\nz = 3']) {
      expect(tester.widget<Text>(find.text(t)).style,
          readerCodeStyle(color: onSurface),
          reason: t);
      // What the engine is actually asked for, after Text merges the
      // ambient DefaultTextStyle. The theme's styles carry
      // `package: openhearth_design`, and a merge hands that package to a
      // family that has none: 'monospace' became
      // 'packages/openhearth_design/monospace', which no font answers to,
      // and the web build drew blank 1-em cells.
      final effective = DefaultTextStyle.of(tester.element(find.text(t)))
          .style
          .merge(tester.widget<Text>(find.text(t)).style);
      expect(effective.fontFamily, 'monospace', reason: t);
    }
  });
}
