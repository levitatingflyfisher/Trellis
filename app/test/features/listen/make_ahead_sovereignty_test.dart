import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// ADR-0003 law 4, amended for make ahead: the show's switch is a gesture
/// for the on-device engines and nothing else. Every Brain entry point
/// takes a `UserGesture`, so code that never constructs one and never
/// imports the Brain's package cannot reach an LLM.
void main() {
  List<File> dartFiles(String dir) => [
        for (final e in Directory(dir).listSync(recursive: true))
          if (e is File && e.path.endsWith('.dart')) e,
      ];

  // What runs with no tap: the line, make ahead, the background check,
  // and everything that starts at launch.
  final unprompted = [
    ...dartFiles('lib/features/listen'),
    ...dartFiles('lib/features/feeds/background'),
    ...dartFiles('lib/bootstrap'),
    File('lib/main.dart'),
  ];

  test('nothing that runs without a tap can reach the Brain', () {
    expect(unprompted, isNotEmpty);
    for (final file in unprompted) {
      final src = file.readAsStringSync();
      expect(src, isNot(contains('package:brain_wiring')),
          reason: '${file.path} imports the Brain');
      expect(src, isNot(contains('UserGesture(')),
          reason: '${file.path} makes a user gesture nobody made');
    }
  });

  test('making an episode ahead talks only to the on-device engines', () {
    final jobs = File('lib/features/listen/make_ahead_jobs.dart')
        .readAsStringSync();
    expect(jobs, isNot(contains('anthropic')));
    expect(jobs, isNot(contains('Brain')));
  });
}
