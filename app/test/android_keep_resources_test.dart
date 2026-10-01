/// Release builds shrink away any resource nothing references by ID, and
/// the media notification's small icon is named only by a string handed
/// to just_audio_background. Shipped 1.5.0 lost it, and Android killed the
/// app the moment playback posted its notification. The keep list must
/// name every resource the Dart side reaches by string.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/bootstrap/bootstrap_io.dart';

void main() {
  test('the shrinker keeps the media notification icon', () {
    final keep = File('android/app/src/main/res/raw/keep.xml');
    expect(keep.existsSync(), isTrue, reason: 'res/raw/keep.xml is missing');
    expect(keep.readAsStringSync(), contains('@$audioNotificationIcon'));
  });

  test('the icon named for the notification exists in the sources', () {
    final dirs = Directory('android/app/src/main/res')
        .listSync()
        .whereType<Directory>()
        .where((d) => d.path.split('/').last.startsWith('drawable'));
    final name = audioNotificationIcon.split('/').last;
    expect(dirs.any((d) => File('${d.path}/$name.png').existsSync()), isTrue);
  });
}
