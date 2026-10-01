import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/intake/share_intake.dart';
import 'package:trellis/features/intake/share_queue.dart';
import 'package:trellis/features/intake/share_source.dart';
import 'package:trellis/main.dart';

import '../support/scripted_fetcher.dart';

const _essay = '<html><head><title>On hedges</title></head><body><article>'
    '<h1>On hedges</h1><p>A laid hedge is cut most of the way through at '
    'the base and bent over, so it grows thick from below. It takes a '
    'winter, a billhook and patience, and it lasts for decades if it is '
    'laid again when it grows up and out of reach of the cattle.</p>'
    '</article></body></html>';

/// A share source with a hand on it: shares waiting before the app is up
/// (a cold start) and shares arriving while it runs (a warm one).
class _FakeShares implements ShareSource {
  final waiting = <SharedPayload>[];
  VoidCallback? _arrival;

  @override
  Future<List<SharedPayload>> takePending() async {
    final all = [...waiting];
    waiting.clear();
    return all;
  }

  @override
  set onArrival(VoidCallback? callback) => _arrival = callback;

  @override
  Future<void> sweep(Set<String> keep) async {}

  void arrive(SharedPayload p) {
    waiting.add(p);
    _arrival?.call();
  }
}

/// Share to Trellis, end to end in the app: a share lands in Latest with
/// a snackbar to open it, a feed asks, and a repeat opens the first.
void main() {
  late AppDatabase db;
  late _FakeShares shares;
  late ScriptedFetcher fetcher;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    shares = _FakeShares();
    fetcher = ScriptedFetcher((url, _) => throw const SocketException('x'));
  });
  tearDown(() => db.close());

  Future<void> boot(WidgetTester tester) async {
    await tester.pumpWidget(
        TrellisApp(db: db, fetcher: fetcher, shareSource: shares));
    await tester.pumpAndSettle();
  }

  testWidgets('a cold start opens at Latest with the shared text and a '
      'snackbar that opens it', (tester) async {
    shares.waiting.add(const SharedPayload(
        text: 'Muse daily: the harbour\n\nBoats came in early.',
        sourceApp: 'Muse'));
    await boot(tester);

    expect(find.text('Saved to Latest'), findsOneWidget);
    expect(find.text('Muse daily: the harbour'), findsOneWidget);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('From Shared'), findsOneWidget,
        reason: 'the work page, with its source a tap away');
  });

  testWidgets('a warm start takes the share where the app is, and Latest '
      'shows it', (tester) async {
    await boot(tester);
    expect(find.text('Nothing in Latest yet.'), findsOneWidget);

    shares.arrive(const SharedPayload(text: 'A note from Dots'));
    await tester.pumpAndSettle();
    expect(find.text('Saved to Latest'), findsOneWidget);
    expect(find.text('A note from Dots'), findsOneWidget);
    expect(find.text('Nothing in Latest yet.'), findsNothing);
  });

  testWidgets('a profile link asks: subscribe or save the page',
      (tester) async {
    await boot(tester);
    shares.arrive(const SharedPayload(
        text: 'https://mastodon.social/@alice'));
    await tester.pumpAndSettle();
    expect(find.text('Subscribe to @alice@mastodon.social'), findsOneWidget);
    expect(find.byKey(const Key('share-save-page')), findsOneWidget);
    expect(fetcher.calls, isEmpty, reason: 'nothing fetched before a choice');
  });

  testWidgets('sharing the same text again opens the first instead of '
      'adding a copy', (tester) async {
    shares.waiting.add(const SharedPayload(text: 'Twice told'));
    await boot(tester);
    await tester.pumpAndSettle(const Duration(seconds: 5));
    shares.arrive(const SharedPayload(text: 'Twice told'));
    await tester.pumpAndSettle();
    expect(find.text('From Shared'), findsOneWidget);
    final profile = (await db.profilesDao.all()).single;
    expect(await db.feedsDao.riverItems(profile.id), hasLength(1));
  });

  testWidgets('a link says Saved to Latest at once, while its page is still '
      'on the way, and the row fills in when it lands', (tester) async {
    final page = Completer<void>();
    fetcher = ScriptedFetcher((url, _) async {
      await page.future;
      return textResponse(_essay,
          headers: {'content-type': 'text/html; charset=utf-8'});
    });
    await boot(tester);
    shares.arrive(const SharedPayload(text: 'https://blog.example/2026/hedges'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Saved to Latest'), findsOneWidget);
    expect(find.text('https://blog.example/2026/hedges'), findsOneWidget);
    expect(fetcher.calls, hasLength(1), reason: 'the page is being read');

    page.complete();
    await tester.pumpAndSettle();
    expect(find.text('On hedges'), findsOneWidget);
    expect(find.text('https://blog.example/2026/hedges'), findsNothing);
  });

  testWidgets('a share arriving while a work page is open is still saved at '
      'once', (tester) async {
    shares.waiting.add(const SharedPayload(text: 'Read twice'));
    await boot(tester);
    await tester.pumpAndSettle(const Duration(seconds: 5));
    // The repeat opens the first work's page and leaves it open.
    shares.arrive(const SharedPayload(text: 'Read twice'));
    await tester.pumpAndSettle();
    expect(find.text('From Shared'), findsOneWidget);

    shares.arrive(const SharedPayload(text: 'A new note meanwhile'));
    await tester.pumpAndSettle();
    final profile = (await db.profilesDao.all()).single;
    final titles = [
      for (final e in await db.feedsDao.riverItems(profile.id)) e.work.title,
    ];
    expect(titles, contains('A new note meanwhile'));
    expect(find.text('Saved to Latest'), findsOneWidget);
  });

  testWidgets('shares wait on disk for their reader; one taken by a closed '
      'app is still there on the next start', (tester) async {
    shares.waiting.add(const SharedPayload(text: 'Waiting on disk'));
    // The queue takes it from the platform, then the app is torn down
    // before any shell saves it.
    final queue = ShareQueue(
        db: db, source: shares, activeProfileId: () => null);
    await queue.start();
    queue.dispose();
    expect(shares.waiting, isEmpty);

    await boot(tester);
    expect(find.text('Waiting on disk'), findsOneWidget);
  });

  testWidgets('a share that failed twice is dropped with one message, '
      'not retried for ever', (tester) async {
    await db.deviceSettingsDao.write(
        'share_pending',
        '[{"id": 1, "profileId": null, "attempts": 2, '
            '"payload": {"text": "poison"}}]');
    await boot(tester);
    expect(find.text('Couldn’t save a shared item.'), findsOneWidget);
    expect(find.text('poison'), findsNothing);
    expect(await db.deviceSettingsDao.read('share_pending'), isNull);
  });

  testWidgets('a file refused on the platform side says why', (tester) async {
    await boot(tester);
    shares.arrive(const SharedPayload(refused: [
      SharedRefusal(
          name: 'book.m4b',
          reason: 'tooBig',
          bytes: 250 * 1024 * 1024,
          limit: 200 * 1024 * 1024),
    ]));
    await tester.pumpAndSettle();
    expect(find.text('Too big to share (250 MB; the limit is 200 MB).'),
        findsOneWidget);
  });

  group('the channel', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel(shareChannelName);

    test('takes what ShareInbox.kt sends, by its method and key names',
        () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return [
          {
            'text': 'hello',
            'subject': 'Subject',
            'sourceApp': 'Muse',
            'files': [
              {'path': '/c/a.md', 'name': 'a.md', 'mimeType': 'text/markdown'},
            ],
          },
        ];
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));

      final got = await ChannelShareSource().takePending();
      expect(calls, ['takePending']);
      final p = got.single;
      expect(p.text, 'hello');
      expect(p.subject, 'Subject');
      expect(p.sourceApp, 'Muse');
      expect(p.files.single.path, '/c/a.md');
      expect(p.files.single.name, 'a.md');
      expect(p.files.single.mimeType, 'text/markdown');
    });

    test('hears shareArrived from the platform', () async {
      final source = ChannelShareSource();
      var heard = 0;
      source.onArrival = () => heard++;
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
              shareChannelName,
              const StandardMethodCodec()
                  .encodeMethodCall(const MethodCall('shareArrived')),
              (_) {});
      expect(heard, 1);
    });

    test('the Kotlin side uses the same names', () {
      final kt = File('android/app/src/main/kotlin/com/openhearth/trellis/'
              'ShareInbox.kt')
          .readAsStringSync();
      expect(kt, contains('"$shareChannelName"'));
      for (final name in const [
        '"takePending"',
        '"sweep"',
        '"keep"',
        '"refused"',
        '"reason"',
        '"tooBig"',
        '"unsupported"',
        '"stalled"',
        '"bytes"',
        '"limit"',
        '"shareArrived"',
        '"text"',
        '"subject"',
        '"sourceApp"',
        '"files"',
        '"path"',
        '"name"',
        '"mimeType"',
      ]) {
        expect(kt, contains(name), reason: name);
      }
    });
  });
}
