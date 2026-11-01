import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/main.dart';
import 'package:trellis/services/device_services.dart';

import '../../support/fake_player.dart';
import '../../support/fake_services.dart';
import '../../support/pick_reader.dart';
import '../../support/scripted_fetcher.dart';
import '../../support/tabs.dart';

/// Boards 0127 and 0131, owner: "it doesn't have a screen or filter to
/// show just downloaded episodes I can see (to reduce memory)". A chip on
/// Latest, beside All, Text and Audio, shows only the episodes whose audio
/// is on this phone, made episodes included, each with its size and the
/// total at the top; one or several can lose their audio and keep
/// everything else. Models & storage's episode-audio row opens the same
/// view.
void main() {
  late Directory dir;
  late AppDatabase db;
  late DeviceServices services;
  late FakeEpisodePlayer player;
  late int profileId;
  late int feedId;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('trellis-on-phone');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    services = testServices(dir);
    player = FakeEpisodePlayer();
    profileId = await db.profilesDao.create('Ada');
    feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://a.test/f', title: 'Night Sky');
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<int> episode(String title,
      {required int at, String? url, String? guid, String? lang}) async {
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: url == null ? 'article' : 'episode',
        title: title,
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: url,
        lang: lang);
    await db.feedsDao.insertEpisode(
        workId: id,
        feedId: feedId,
        guid: guid ?? 'g-$title',
        enclosureUrl: url,
        publishedAtMs: at);
    return id;
  }

  File onDisk(int id, String url, int bytes) {
    final f = services.audioFileFor(id, url)..parent.createSync(recursive: true);
    return f..writeAsBytesSync(List.filled(bytes, 1));
  }

  late int aurora, comet, made, article;
  late File auroraAudio, madeAudio, auroraDecoded;

  Future<void> seed() async {
    aurora = await episode('Aurora season',
        at: 3000, url: 'https://a.test/aurora.mp3', lang: 'en');
    comet = await episode('Comet watch',
        at: 2000, url: 'https://a.test/comet.mp3', lang: 'en');
    article = await episode('Star chart', at: 1000);
    made = await episode('Aurora season (Spanish)',
        at: 3001,
        url: 'https://spoken.trellis.invalid/$aurora-es.ogg',
        guid: 'spoken:$aurora:es',
        lang: 'es');
    auroraAudio = onDisk(aurora, 'https://a.test/aurora.mp3', 3000);
    madeAudio =
        onDisk(made, 'https://spoken.trellis.invalid/$aurora-es.ogg', 2000);
    // A decoded copy transcribing left: part of what the episode takes.
    auroraDecoded = services.pcmFileFor(aurora)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(List.filled(1000, 2));
    // The transcript stays when the audio goes.
    await db.spineDao.insertSegments(
        aurora, const [(idx: 0, kind: 'prose', text: 'Lights.')]);
    await db.spineDao.insertAlignments(
        aurora, const [(segmentIdx: 0, tStartMs: 0, tEndMs: 900)]);
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(TrellisApp(
        db: db,
        fetcher: ScriptedFetcher((u, h) => textResponse('')),
        createPlayer: () => player,
        services: services));
    await tester.pumpAndSettle();
    await pickReader(tester, 'Ada');
  }

  Future<void> onPhone(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('chip-on-phone')));
    await tester.pumpAndSettle();
  }

  String total(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('on-phone-total'))).data!;

  testWidgets('the chip sits beside All, Text and Audio, and shows only '
      'episodes whose audio is on the phone, made ones too, each with its '
      'size and the total at the top', (tester) async {
    await seed();
    await pumpApp(tester);

    final chip = find.byKey(const Key('chip-on-phone'));
    expect(chip, findsOneWidget);
    // The owner's word (12 Nov: "I don't see a place to see
    // 'downloads'").
    expect(find.descendant(of: chip, matching: find.text('Downloads')),
        findsOneWidget);

    await onPhone(tester);

    expect(find.byKey(Key('latest-row-$aurora')), findsOneWidget);
    expect(find.byKey(Key('latest-row-$made')), findsOneWidget);
    expect(find.byKey(Key('latest-row-$comet')), findsNothing);
    expect(find.byKey(Key('latest-row-$article')), findsNothing);
    expect(
        tester.widget<Text>(find.byKey(Key('on-phone-size-$aurora'))).data,
        '4.0 kB on this phone');
    expect(tester.widget<Text>(find.byKey(Key('on-phone-size-$made'))).data,
        '2.0 kB on this phone');
    expect(total(tester), '2 episodes, 6.0 kB in all.');
    // Biggest first: the view is for freeing space.
    expect(tester.getRect(find.byKey(Key('latest-row-$aurora'))).top,
        lessThan(tester.getRect(find.byKey(Key('latest-row-$made'))).top));

    // All brings the whole list back.
    await tester.tap(find.byKey(const Key('chip-all')));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('latest-row-$comet')), findsOneWidget);
  });

  // The owner never saw the chip: it sat at the end of a sideways row,
  // off the edge of a narrow phone. The row wraps, so it is on screen.
  for (final (width, scale) in [(320.0, 1.3), (360.0, 1.3), (412.0, 1.0)]) {
    testWidgets('at ${width.toInt()} dp and text $scale the Downloads chip '
        'is wholly on screen, without scrolling', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      await seed();
      await pumpApp(tester);

      final rect = tester.getRect(find.byKey(const Key('chip-on-phone')));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(width));
      expect(find.byKey(const Key('chip-on-phone')).hitTestable(),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('one episode’s audio goes after a plain confirm; the episode '
      'and its transcript stay', (tester) async {
    await seed();
    await pumpApp(tester);
    await onPhone(tester);

    final remove = find.byKey(Key('on-phone-remove-$aurora'));
    expect(tester.getSize(remove).height, greaterThanOrEqualTo(48));
    expect(find.byTooltip('Remove this episode’s audio'), findsWidgets);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(
        find.descendant(
            of: dialog,
            matching: find.textContaining('Frees 4.0 kB now. The episode '
                'stays, with its transcript, your place and your study '
                'cards.')),
        findsOneWidget);
    await tester.tap(find.text('Remove audio'));
    await tester.pumpAndSettle();

    expect(auroraAudio.existsSync(), isFalse);
    expect(auroraDecoded.existsSync(), isFalse);
    expect(madeAudio.existsSync(), isTrue);
    expect(await db.spineDao.workById(aurora), isNotNull);
    expect(await db.spineDao.segmentCount(aurora), 1);
    expect(find.byKey(Key('latest-row-$aurora')), findsNothing);
    expect(total(tester), '1 episode, 2.0 kB in all.');
  });

  // Seen on the emulator: an episode whose transcription was paused kept
  // its audio, as it should, but the confirm had already promised to free
  // its space. An episode that keeps its audio is said so before, not
  // after.
  testWidgets('the episode playing keeps its audio, and no confirm promises '
      'its space', (tester) async {
    await seed();
    await pumpApp(tester);
    await onPhone(tester);

    await tester.tap(find.descendant(
        of: find.byKey(Key('latest-row-$aurora')),
        matching: find.text('Play')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('on-phone-remove-$aurora')));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('Frees'), findsNothing);
    expect(find.textContaining('keeps its audio'), findsOneWidget);
    expect(auroraAudio.existsSync(), isTrue);
  });

  testWidgets('several at once through the app’s own selection; a made '
      'episode is said to come back by the tap that made it',
      (tester) async {
    await seed();
    await pumpApp(tester);
    await onPhone(tester);

    await tester.longPress(find.byKey(Key('latest-row-$aurora')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('selection-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bulk-remove-audio')));
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    expect(find.descendant(of: dialog, matching: find.text(
        'Remove the audio of 2 episodes?')), findsOneWidget);
    expect(
        find.descendant(
            of: dialog,
            matching: find.textContaining('A made episode is made again by '
                'the same Listen tap on its original.')),
        findsOneWidget);
    await tester.tap(
        find.descendant(of: dialog, matching: find.text('Remove audio')));
    await tester.pumpAndSettle();

    expect(auroraAudio.existsSync(), isFalse);
    expect(madeAudio.existsSync(), isFalse);
    expect(await db.spineDao.workById(made), isNotNull);
    expect(total(tester), 'No episode audio is on this phone.');
    // The chips stay, so the way back is there.
    expect(find.byKey(const Key('chip-all')), findsOneWidget);
  });

  testWidgets('Models & storage’s episode audio opens the same view, with '
      'Clear all kept as the second choice', (tester) async {
    await seed();
    await pumpApp(tester);
    await openSetting(tester, const Key('open-models'));

    final see = find.byKey(const Key('storage-audio-episodes'));
    await tester.scrollUntilVisible(see, 300,
        scrollable: find.byType(Scrollable).last);
    expect(
        find.descendant(
            of: find.byKey(const Key('storage-audio-clear')),
            matching: find.text('Clear all')),
        findsOneWidget);
    await tester.tap(see);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('on-phone-total')), findsOneWidget);
    expect(find.byKey(Key('latest-row-$aurora')), findsOneWidget);
    expect(find.byKey(Key('latest-row-$comet')), findsNothing);
  });
}
