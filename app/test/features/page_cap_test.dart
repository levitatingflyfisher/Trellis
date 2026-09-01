import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/shared/capped_body.dart';
import 'package:trellis/main.dart';

import '../support/fake_player.dart';
import '../support/scripted_fetcher.dart';
import '../support/pick_reader.dart';

/// Fleet rule: a phone layout is not stretched across a tablet or a
/// desktop browser (audit about-face-08, dfh-08). Every Scaffold body sits
/// in [CappedBody] (OhPage), except the two recorded here.
const exempt = {
  // Sets its own centred column at the reader's chosen width (the
  // typography settings' "max text width"), which may be wider than the
  // phone cap on purpose.
  'lib/features/reader/reader_screen.dart':
      'the reader sets its own column at the chosen text width',
  // The shell's body IS a tab screen, which carries its own cap.
  'lib/features/profiles/home_shell.dart': 'its body is a capped tab screen',
};

void main() {
  test('every Scaffold body is capped (source check)', () {
    final missing = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final path = f.path.replaceAll(r'\', '/');
      if (exempt.containsKey(path)) continue;
      final src = f.readAsStringSync();
      final scaffolds = RegExp(r'\bScaffold\(').allMatches(src).length;
      final capped = RegExp(r'body: CappedBody\(').allMatches(src).length;
      if (capped < scaffolds) missing.add('$path ($capped of $scaffolds)');
    }
    expect(missing, isEmpty);
  });

  testWidgets('the Library at 1024 dp is a capped, centred column',
      (tester) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await db.profilesDao.create('Ada');
    await db.spineDao.insertWork(
        profileId: id,
        kind: 'note',
        title: 'Wide',
        persistence: 'work',
        firstSeenEpochDay: 100);
    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((u, h) => textResponse('')),
        createPlayer: () => FakeEpisodePlayer()));
    await tester.pumpAndSettle();
    await pickReader(tester, 'Ada');
    final row = tester.getRect(find.ancestor(
        of: find.text('Wide'), matching: find.byType(ListTile)).first);
    expect(row.width, lessThanOrEqualTo(640));
    expect(row.center.dx, closeTo(512, 1));
    expect(find.byType(CappedBody), findsWidgets);
  });
}
