import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The home-screen widget (1.5.5): the Android half no widget test can
/// see. The launcher finds a widget only through a receiver for
/// APPWIDGET_UPDATE naming its provider XML, and the picker shows the
/// label and description named here.
void main() {
  const res = 'android/app/src/main/res';
  final manifest = File('android/app/src/main/AndroidManifest.xml');
  late String receiver;

  setUpAll(() {
    receiver = RegExp(
            r'<receiver\s[^>]*android:name="\.TrellisWidget".*?</receiver>',
            dotAll: true)
        .firstMatch(manifest.readAsStringSync())!
        .group(0)!;
  });

  String stringRes(String name) => RegExp('<string name="$name">([^<]*)<')
      .firstMatch(File('$res/values/widget.xml').readAsStringSync())!
      .group(1)!;

  test('a receiver takes APPWIDGET_UPDATE and names the provider XML', () {
    expect(receiver, contains('android.appwidget.action.APPWIDGET_UPDATE'));
    expect(receiver, contains('android:name="android.appwidget.provider"'));
    expect(receiver, contains('android:resource="@xml/trellis_widget_info"'));
    expect(File('$res/xml/trellis_widget_info.xml').existsSync(), isTrue);
  });

  test('taps reach only a receiver no other app can call', () {
    final text = manifest.readAsStringSync();
    final tap = RegExp(
            r'<receiver\s[^>]*android:name="\.WidgetTapReceiver"[^>]*/>',
            dotAll: true)
        .firstMatch(text)
        ?.group(0);
    expect(tap, isNotNull);
    expect(tap, contains('android:exported="false"'));
    expect(receiver, isNot(contains('TAP_')),
        reason: 'the exported provider takes only APPWIDGET_UPDATE');
    final provider = File(
            'android/app/src/main/kotlin/com/openhearth/trellis/TrellisWidget.kt')
        .readAsStringSync();
    expect(provider, isNot(contains('override fun onReceive')),
        reason: 'no custom action is handled by the exported provider');
    expect(provider,
        contains('Intent(context, WidgetTapReceiver::class.java)'));
  });

  group('Play on the card can never be refused quietly (owner, 9 Nov: '
      '"Clicking play on the widget doesn\'t always work")', () {
    const kotlin = 'android/app/src/main/kotlin/com/openhearth/trellis';
    String source(String name) => File('$kotlin/$name').readAsStringSync();

    test('a card drawn ready sends Play to an activity: the one launch '
        'Android always allows from a widget', () {
      final widget = source('TrellisWidget.kt');
      expect(widget, isNot(contains('broadcast(context, TAP_PLAY')));
      expect(widget, contains('Intent(context, WidgetPlayActivity::class.java)'));
      final play = RegExp(
              r'<activity\s[^>]*android:name="\.WidgetPlayActivity"[^>]*/>',
              dotAll: true)
          .firstMatch(manifest.readAsStringSync())
          ?.group(0);
      expect(play, isNotNull);
      expect(play, contains('android:exported="false"'));
      expect(play, contains('android:theme="@android:style/Theme.NoDisplay"'),
          reason: 'nothing flashes on the screen when a Play can play');
      expect(play, contains('android:excludeFromRecents="true"'));
      expect(play, contains('android:taskAffinity=""'),
          reason: 'it must not bring the app\'s own task forward');
    });

    test('it plays when the app holds the audio, and otherwise opens the app',
        () {
      final activity = source('WidgetPlayActivity.kt');
      expect(activity, contains('WidgetBridge.deliver("play"'));
      expect(activity, contains('startActivity(TrellisWidget.playIntent('));
      expect(activity, contains('finish()'));
    });

    test('the receiver no longer tries a launch Android may refuse', () {
      final receiver = source('WidgetTapReceiver.kt');
      expect(receiver, isNot(contains('startActivity')));
      expect(receiver, isNot(contains('TAP_PLAY')));
    });
  });

  test('a fresh process redraws the card, so a killed app leaves no '
      'stale Play', () {
    expect(manifest.readAsStringSync(),
        contains('android:name=".TrellisApplication"'));
    final app = File('android/app/src/main/kotlin/com/openhearth/trellis/'
            'TrellisApplication.kt')
        .readAsStringSync();
    expect(app, contains('TrellisWidget.refresh(this)'));
    expect(app.indexOf('WidgetBridge.markCold(this)'), greaterThan(-1));
    expect(app.indexOf('WidgetBridge.markCold(this)'),
        lessThan(app.indexOf('TrellisWidget.refresh(this)')),
        reason: 'a dead process’s player is neither playing nor loaded, '
            'so the first redraw offers no headless Play');
  });

  test('it is called Trellis, and says what it is for', () {
    expect(receiver, contains('android:label="@string/widget_label"'));
    expect(stringRes('widget_label'), 'Trellis');
    final info = File('$res/xml/trellis_widget_info.xml').readAsStringSync();
    expect(info, contains('android:description="@string/widget_description"'));
    expect(stringRes('widget_description'), 'Resume listening and reading');
  });

  test('about 4x1 by default, down to 2x1, resizable, with a preview', () {
    final info = File('$res/xml/trellis_widget_info.xml').readAsStringSync();
    expect(info, contains('android:targetCellWidth="4"'));
    expect(info, contains('android:targetCellHeight="1"'));
    expect(info, contains('android:minResizeWidth="110dp"'));
    expect(info, contains('android:minHeight="56dp"'),
        reason: '48dp buttons plus the card’s padding; never placed shorter');
    expect(info, contains('android:minResizeHeight="56dp"'));
    expect(info, contains('android:resizeMode="horizontal|vertical"'));
    expect(info, contains('android:previewLayout="@layout/widget_trellis"'));
    expect(info, contains('android:previewImage='));
    expect(info, contains('android:updatePeriodMillis="0"'),
        reason: 'the app pushes changes; no timer wakes the phone');
  });

  test('every button is a 48dp target with something to say', () {
    final layout = File('$res/layout/widget_trellis.xml').readAsStringSync();
    final buttons =
        RegExp(r'<ImageButton.*?/>', dotAll: true).allMatches(layout);
    expect(buttons, hasLength(3));
    for (final b in buttons) {
      final text = b.group(0)!;
      expect(text, contains('android:layout_width="48dp"'));
      expect(text, contains('android:layout_height="48dp"'));
      expect(text, contains('android:contentDescription="@string/'));
    }
  });

  test('day and night colours, and the launcher’s own corner radius', () {
    expect(File('$res/values/widget.xml').readAsStringSync(),
        contains('name="widget_surface"'));
    expect(File('$res/values-night/widget.xml').readAsStringSync(),
        contains('name="widget_surface"'));
    expect(File('$res/values-v31/widget.xml').readAsStringSync(),
        contains('@android:dimen/system_app_widget_background_radius'));
    expect(File('$res/layout/widget_trellis.xml').readAsStringSync(),
        contains('android:id="@android:id/background"'));
  });

  test('the main activity hands widget taps to Dart', () {
    final activity = File(
            'android/app/src/main/kotlin/com/openhearth/trellis/MainActivity.kt')
        .readAsStringSync();
    expect(activity, contains('WidgetBridge.attach('));
    expect(RegExp(r'WidgetBridge\.receive\(').allMatches(activity),
        hasLength(2), reason: 'onCreate and onNewIntent');
  });
}
