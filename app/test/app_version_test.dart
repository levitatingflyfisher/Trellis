import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/app_version.dart';

void main() {
  test('the version in the User-Agent is the one in pubspec.yaml', () {
    final line = File('pubspec.yaml')
        .readAsLinesSync()
        .firstWhere((l) => l.startsWith('version:'));
    final version = line.substring('version:'.length).trim().split('+').first;
    expect(appVersion, version);
    expect(trellisUserAgent, startsWith('Trellis/$version '));
  });
}
