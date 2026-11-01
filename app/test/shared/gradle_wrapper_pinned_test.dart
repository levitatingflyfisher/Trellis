import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Gradle wrapper downloads Gradle itself on a clean machine and runs
/// it with the build's full rights. Without a checksum it runs whatever
/// that address serves; with one, a changed file stops the build.
void main() {
  test('the Gradle download is pinned by its sha256', () {
    final props =
        File('android/gradle/wrapper/gradle-wrapper.properties').readAsStringSync();
    expect(props, contains('distributionUrl='));
    expect(
        RegExp(r'^distributionSha256Sum=[0-9a-f]{64}$', multiLine: true)
            .hasMatch(props),
        isTrue,
        reason: 'gradle-wrapper.properties has no distributionSha256Sum');
  });
}
