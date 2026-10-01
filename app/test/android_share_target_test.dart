import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Share to Trellis (1.5.5): the manifest half, which no widget test can
/// see. Trellis appears in the share sheet for exactly what it can take,
/// and nothing broader: a `*/*` filter would offer Trellis for every
/// photo and PDF only to refuse it.
void main() {
  final manifest = File('android/app/src/main/AndroidManifest.xml');
  final activity = File(
      'android/app/src/main/kotlin/com/openhearth/trellis/MainActivity.kt');

  late String mainActivity;
  late List<String> filters;

  setUpAll(() {
    final text = manifest.readAsStringSync();
    mainActivity = RegExp(
            r'<activity\s[^>]*android:name="\.MainActivity".*?</activity>',
            dotAll: true)
        .firstMatch(text)!
        .group(0)!;
    filters = [
      for (final m in RegExp(r'<intent-filter>.*?</intent-filter>',
              dotAll: true)
          .allMatches(mainActivity))
        m.group(0)!,
    ];
  });

  Set<String> mimesFor(String action) => {
        for (final f in filters)
          if (f.contains('android.intent.action.$action"'))
            for (final m in RegExp(r'android:mimeType="([^"]+)"').allMatches(f))
              m.group(1)!,
      };

  bool hasDefaultCategory(String action) => filters
      .where((f) => f.contains('android.intent.action.$action"'))
      .every((f) => f.contains('android.intent.category.DEFAULT'));

  test('the guard can see its inputs', () {
    expect(manifest.existsSync(), isTrue);
    expect(activity.existsSync(), isTrue);
    expect(filters, isNotEmpty);
  });

  test('a single share takes text, links and the files Trellis reads', () {
    expect(mimesFor('SEND'), {
      'text/plain',
      'text/markdown',
      'text/x-markdown',
      'text/html',
      'application/epub+zip',
      'audio/*',
    });
    expect(hasDefaultCategory('SEND'), isTrue,
        reason: 'the chooser only offers activities in DEFAULT');
  });

  test('several files at once take the same file kinds', () {
    expect(mimesFor('SEND_MULTIPLE'), {
      'text/plain',
      'text/markdown',
      'text/x-markdown',
      'text/html',
      'application/epub+zip',
      'audio/*',
    });
    expect(hasDefaultCategory('SEND_MULTIPLE'), isTrue);
  });

  test('nothing broader: no wildcard, and no PDF, which the reader can’t '
      'open', () {
    final all = {...mimesFor('SEND'), ...mimesFor('SEND_MULTIPLE')};
    expect(all, isNot(contains('*/*')));
    expect(all, isNot(contains('text/*')));
    expect(all, isNot(contains('application/*')));
    expect(all, isNot(contains('application/pdf')));
  });

  test('the launcher filter is still there', () {
    expect(
        filters.any((f) =>
            f.contains('android.intent.action.MAIN') &&
            f.contains('android.intent.category.LAUNCHER')),
        isTrue);
  });

  test('a share from another app reaches the one activity that holds the '
      'engine', () {
    // audio_service hands every MainActivity the same cached engine. A
    // share started in the sender's task would make a second activity and
    // attach that engine to it; singleTask with its own affinity routes the
    // share to the existing one, through onNewIntent.
    expect(mainActivity, contains('android:launchMode="singleTask"'));
    expect(mainActivity, contains('android:taskAffinity=""'));
    final kt = activity.readAsStringSync();
    expect(kt, contains('override fun onNewIntent'));
    expect(kt, contains('ShareInbox.receive(this, intent)'));
    expect(kt, contains('ShareInbox.attach('));
  });
}
