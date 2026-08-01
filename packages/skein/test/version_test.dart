/// The version has one source of truth: [skeinVersion] in
/// lib/src/version.dart. It appears in two user/network-facing places
/// (/api/health's body, the trellis-skein/<version> User-Agent) that must
/// never drift from pubspec.yaml's declared version — the conventions.md
/// failure mode ("the claim outlived the code").
import 'dart:io';

import 'package:skein/skein.dart';
import 'package:test/test.dart';

void main() {
  test('skeinVersion matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(r'^version:\s*(\S+)', multiLine: true)
        .firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml must declare a version');
    expect(skeinVersion, match!.group(1));
  });
}
