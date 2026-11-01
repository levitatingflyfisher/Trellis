import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhearth_design/openhearth_design.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/listen/listen_chain.dart';
import 'package:trellis/features/listen/spoken_episode.dart' show VoiceKind;
import 'package:trellis/features/listen/listen_jobs.dart';
import 'package:trellis/features/listen/make_ahead.dart';
import 'package:trellis/features/listen/make_ahead_jobs.dart';
import 'package:trellis/features/models/consent.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/reader/speech/speech_engine.dart';
import 'package:trellis/features/transcribe/foreground_gate.dart';

import '../../support/fake_player.dart';
import '../../support/fake_services.dart';

typedef _Ep = ({Work work, Episode episode});

/// Make ahead through the real line (owner, 10 November 2026: "Yes, for
/// shows I pick"). Stand-ins only for the engines and the device's two
/// meters.
void main() {
  late Directory dir;
  late AppDatabase db;
  late int profileId;
  late int feedId;
  late FakeEpisodePlayer player;
  late PlayerController controller;
  late RecordingForegroundGate gate;
  late List<DownloadItem> models;
  late int transcribed;
  late int translated;
  late bool wifiAndCharging;
  late Map<int, Completer<void>> held;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('trellis-make-ahead');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://cast.test/feed', title: 'Show');
    await db.deviceSettingsDao.write(learningLanguageKey, 'fr');
    player = FakeEpisodePlayer();
    controller = PlayerController(
        db: db, profileId: profileId, createPlayer: () => player);
    gate = RecordingForegroundGate();
    models = [];
    transcribed = 0;
    translated = 0;
    wifiAndCharging = true;
    held = {};
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
    dir.deleteSync(recursive: true);
  });

  var serial = 0;
  Future<_Ep> episode(String title) async {
    final n = ++serial;
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: 'episode',
        title: title,
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/$n.mp3',
        lang: 'en');
    await db.feedsDao.insertEpisode(
        workId: id,
        feedId: feedId,
        guid: 'g$n',
        enclosureUrl: 'https://cast.test/$n.mp3',
        publishedAtMs: 5000 + n * 1000);
    return (
      work: (await db.spineDao.workById(id))!,
      episode: (await db.feedsDao.episodeOf(id))!,
    );
  }

  File fileOf(int workId, String url) =>
      testServices(dir).audioFileFor(workId, url);

  ListenChain chain(JobForegroundGate g) => ListenChain(
        db: db,
        foreground: g,
        transcribe: (w, e) async {
          transcribed++;
          await db.spineDao.insertSegments(
              w.id, const [(idx: 0, kind: 'prose', text: 'Hello there.')]);
          await db.spineDao.insertAlignments(
              w.id, const [(segmentIdx: 0, tStartMs: 0, tEndMs: 2000)]);
        },
        translate: (w, source, target, progress) async {
          translated++;
          progress(2, 5);
          await held[w.id]?.future;
          await db.spineDao.upsertTranslationSentence(
              workId: w.id,
              segmentIdx: 0,
              sentenceIdx: 0,
              lang: target,
              sourceText: 'Hello there.',
              body: 'Bonjour.');
          return null;
        },
        voiceFor: (_, lang) async => (
          name: 'Test voice',
          voiceKind: VoiceKind.machine,
          say: (String t, SpeechPace p) async =>
              SynthResult(samples: Float32List(100), sampleRate: 1000),
        ),
        audioFileFor: fileOf,
        tempDir: Directory('${dir.path}/tmp'),
      );

  ListenJobs jobs({JobForegroundGate? over, bool Function()? inFront}) =>
      ListenJobs(
        db: db,
        chain: chain(over ?? gate),
        languagesFor: ({required workLang, required feedLang}) =>
            const ['fr', 'es'],
        downloadsFor: (work, episode, lang) async => models,
        player: controller,
        inFront: inFront ?? () => true,
        makeAhead: MakeAhead(
          db: db,
          conditionsMet: () async => wifiAndCharging,
          modelsNeeded: (w, e, l, {required forShow}) async => models,
          audioFileFor: fileOf,
          watchEvery: const Duration(milliseconds: 10),
        ),
      );

  Future<void> until(bool Function() done, {String? what}) async {
    for (var i = 0; i < 400 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(done(), isTrue, reason: 'never happened: ${what ?? 'condition'}');
  }

  Future<void> beats([int n = 12]) async {
    for (var i = 0; i < n; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  bool made(ListenJobs j, _Ep e) =>
      j.offerFor(e.work, e.episode)?.ready ?? false;
  bool making(ListenJobs j, _Ep e) =>
      j.offerFor(e.work, e.episode)?.making ?? false;

  Future<ListenJobs> started({JobForegroundGate? over}) async {
    final j = jobs(over: over);
    await j.ready;
    await j.resumeLine();
    return j;
  }

  Future<int?> spokenId(_Ep e) async => (await (db.select(db.episodes)
            ..where((r) => r.guid.equals('spoken:${e.work.id}:fr')))
          .getSingleOrNull())
      ?.workId;

  Future<void> markPlayed(int workId) =>
      (db.update(db.episodes)..where((e) => e.workId.equals(workId)))
          .write(const EpisodesCompanion(finishedAtMs: Value(123)));

  test('LAW: a new episode of a show nobody switched on is never made',
      () async {
    await episode('Old');
    final j = await started();
    final e = await episode('New');
    await j.makeAheadPass();
    await beats();
    expect(transcribed, 0);
    expect(gate.events, isEmpty);
    expect(await spokenId(e), isNull);
  });

  test('a show switched on: what arrives after is made, nothing older, and '
      'its row says Play in French. It never plays by itself', () async {
    final old = await episode('Old');
    final j = await started();
    await j.makeAhead!.switchOn(feedId);
    final e = await episode('New');

    await j.makeAheadPass();
    await until(() => made(j, e), what: 'made ahead');

    expect(j.offerFor(e.work, e.episode)!.label, 'Play in French');
    expect(await spokenId(old), isNull);
    expect(controller.current, isNull, reason: 'it never plays by itself');
    expect(player.loadedFilePath, isNull);
  });

  test('neither Wi-Fi nor charging: it waits; both back: it makes it',
      () async {
    final j = await started();
    await j.makeAhead!.switchOn(feedId);
    final e = await episode('New');
    wifiAndCharging = false;

    await j.makeAheadPass();
    await beats();
    expect(transcribed, 0);
    expect(j.makeAhead!.isWaiting(e.work.id), isTrue);

    wifiAndCharging = true;
    await j.makeAheadPass();
    await until(() => made(j, e));
  });

  test('conditions gone mid-job: it stops at the next safe point, keeps '
      'what it made, and picks up later', () async {
    final j = await started();
    await j.makeAhead!.switchOn(feedId);
    final e = await episode('New');
    final gateOpen = held[e.work.id] = Completer<void>();

    await j.makeAheadPass();
    await until(() => making(j, e) && translated == 1, what: 'translating');
    wifiAndCharging = false;
    await beats(4);
    gateOpen.complete();
    await until(() => !making(j, e), what: 'stopped');

    expect(await spokenId(e), isNull);
    expect(j.makeAhead!.isWaiting(e.work.id), isTrue);
    expect(transcribed, 1);

    wifiAndCharging = true;
    await j.makeAheadPass();
    await until(() => made(j, e), what: 'picked up again');
    expect(transcribed, 1, reason: 'the transcript was kept');
  });

  test('Android refuses the service behind a dark screen: nothing runs '
      'unprotected, and it stays waiting', () async {
    final j = await started();
    await j.makeAhead!.switchOn(feedId);
    final e = await episode('New');
    gate.allowStart = false;

    await j.makeAheadPass();
    await beats();
    expect(transcribed, 0);
    expect(gate.events, ['refused:New']);
    expect(j.makeAhead!.isWaiting(e.work.id), isTrue);

    gate.allowStart = true;
    await j.makeAheadPass();
    await until(() => made(j, e));
  });

  test('the next episode starts under the last one’s service, so a dark '
      'screen cannot stop the run partway', () async {
    final inner = RecordingForegroundGate();
    final shared = SharedJobForegroundGate(inner);
    final j = await started(over: shared);
    await j.makeAhead!.switchOn(feedId);
    final a = await episode('Older');
    final b = await episode('Newer');
    final waitOnNewer = held[b.work.id] = Completer<void>();

    await j.makeAheadPass();
    await until(() => making(j, b), what: 'first under way');
    // The screen goes dark: from here Android refuses a fresh start.
    inner.allowStart = false;
    waitOnNewer.complete();

    await until(() => made(j, a), what: 'the second one made too');
    expect(inner.events, isNot(contains(startsWith('refused'))));
  });

  test('a tap goes ahead of made-ahead work and the made-ahead job gives '
      'way at once, then carries on', () async {
    final j = await started();
    await j.makeAhead!.switchOn(feedId);
    final ahead = await episode('Ahead');
    final gateOpen = held[ahead.work.id] = Completer<void>();
    await j.makeAheadPass();
    await until(() => making(j, ahead) && translated == 1);

    final tapped = await episode('Tapped');
    await j.ask(tapped.work, 'fr');
    gateOpen.complete();

    await until(() => made(j, tapped), what: 'tap made');
    expect(controller.current?.title, contains('Tapped'),
        reason: 'the tap plays when ready');
    await j.makeAheadPass();
    await until(() => made(j, ahead), what: 'made ahead carries on');
    expect(controller.current?.title, contains('Tapped'),
        reason: 'the made-ahead one must not take over the player');
    expect((await spokenId(tapped))!, lessThan((await spokenId(ahead))!),
        reason: 'the tap was finished first, though it came second');
  });

  test('a tap behind a made-ahead job writes only the tap on the line a '
      'launch restarts', () async {
    final j = await started();
    await j.makeAhead!.switchOn(feedId);
    final ahead = await episode('Ahead');
    held[ahead.work.id] = Completer<void>();
    await j.makeAheadPass();
    await until(() => making(j, ahead) && translated == 1);

    final tapped = await episode('Tapped');
    held[tapped.work.id] = Completer<void>();
    await j.ask(tapped.work, 'fr');
    await j.saved;

    expect(await db.deviceSettingsDao.read(listenLineKey),
        '[{"workId":${tapped.work.id},"lang":"fr"}]');
  });

  test('tapping an episode still waiting makes it the person’s: it is not '
      'counted and never removed for room', () async {
    final j = await started();
    await j.makeAhead!.switchOn(feedId);
    final e = await episode('New');
    wifiAndCharging = false;
    await j.makeAheadPass();
    await until(() => j.makeAhead!.isWaiting(e.work.id));

    await j.ask(e.work, 'fr');
    await until(() => made(j, e), what: 'the tap is not held back');
    expect(j.makeAhead!.isWaiting(e.work.id), isFalse);
    expect(j.makeAhead!.line(), isNull,
        reason: 'it is not made-ahead audio');
  });

  test('Stop on a row being made ahead is final: it is not picked again',
      () async {
    final j = await started();
    await j.makeAhead!.switchOn(feedId);
    final e = await episode('New');
    final gateOpen = held[e.work.id] = Completer<void>();
    await j.makeAheadPass();
    await until(() => making(j, e) && translated == 1);

    j.stop(e.work.id);
    gateOpen.complete();
    await until(() => !making(j, e));
    await j.makeAheadPass();
    await beats();

    expect(await spokenId(e), isNull);
    expect(j.makeAhead!.isWaiting(e.work.id), isFalse);
    expect(translated, 1);
  });

  group('models', () {
    test('a missing model nobody agreed to: not fetched, not started',
        () async {
      final j = await started();
      await j.makeAhead!.switchOn(feedId);
      final e = await episode('New');
      models = [const DownloadItem('Translator')];

      await j.makeAheadPass();
      await beats();
      expect(transcribed, 0);
      expect(j.makeAhead!.isWaiting(e.work.id), isTrue);
    });

    test('agreed once when switching on, for that language: it goes ahead',
        () async {
      final j = await started();
      await j.makeAhead!.switchOn(feedId, agreedLang: 'fr');
      final e = await episode('New');
      models = [const DownloadItem('Translator')];

      await j.makeAheadPass();
      await until(() => made(j, e));
    });

    test('agreed for another language does not cover this one', () async {
      final j = await started();
      await j.makeAhead!.switchOn(feedId, agreedLang: 'es');
      await episode('New');
      models = [const DownloadItem('Translator')];

      await j.makeAheadPass();
      await beats();
      expect(transcribed, 0);
    });
  });

  test('at most 3 per show, newest first; a played one frees a slot for the '
      'newest not yet picked', () async {
    final j = await started();
    await j.makeAhead!.switchOn(feedId);
    final eps = [for (var i = 0; i < 5; i++) await episode('E$i')];

    await j.makeAheadPass();
    await until(() => made(j, eps[4]) && made(j, eps[3]) && made(j, eps[2]));
    await beats();
    expect(transcribed, 3);
    expect(await spokenId(eps[1]), isNull);

    await markPlayed(await spokenId(eps[4]) as int);
    final next = await episode('Newest');
    await j.refresh();
    await j.makeAheadPass();
    await until(() => made(j, next));
    await beats();
    expect(transcribed, 4, reason: 'older ones were passed over');
  });

  group('the room limit', () {
    Future<void> big(_Ep e) async {
      final id = await spokenId(e);
      final url = (await db.feedsDao.episodeOf(id!))!.enclosureUrl!;
      final f = fileOf(id, url).openSync(mode: FileMode.append);
      f.truncateSync(600000000);
      f.closeSync();
    }

    Future<bool> onDisk(_Ep e) async {
      final id = await spokenId(e);
      final url = (await db.feedsDao.episodeOf(id!))!.enclosureUrl!;
      return fileOf(id, url).existsSync();
    }

    setUp(() async {
      await db.deviceSettingsDao.write(makeAheadLimitKey, '1');
    });

    Future<(ListenJobs, _Ep, _Ep)> twoMade() async {
      final j = await started();
      await j.makeAhead!.switchOn(feedId);
      final a = await episode('A');
      await j.makeAheadPass();
      await until(() => made(j, a));
      final b = await episode('B');
      await j.makeAheadPass();
      await until(() => made(j, b));
      await big(a);
      await big(b);
      return (j, a, b);
    }

    test('over the limit the oldest made-ahead audio goes, and its row '
        'goes back to Listen', () async {
      final (j, a, b) = await twoMade();
      await j.makeAheadPass();
      await until(() => !made(j, a), what: 'oldest removed');
      expect(await onDisk(a), isFalse);
      expect(await onDisk(b), isTrue);
      expect(j.offerFor(a.work, a.episode)!.label, 'Listen in French');
    });

    test('audio somebody marked Keep is never removed', () async {
      final (j, a, b) = await twoMade();
      await db.spineDao.setPersistence((await spokenId(a))!, 'work');
      await db.spineDao.setPersistence((await spokenId(b))!, 'work');
      await j.makeAheadPass();
      await beats();
      expect(await onDisk(a), isTrue);
      expect(await onDisk(b), isTrue);
    });

    test('audio somebody made by tapping is never removed', () async {
      final j = await started();
      await j.makeAhead!.switchOn(feedId);
      final tapped = await episode('Tapped');
      await j.ask(tapped.work, 'fr');
      await until(() => made(j, tapped));
      await big(tapped);
      final a = await episode('A');
      await j.makeAheadPass();
      await until(() => made(j, a));
      await big(a);
      final b = await episode('B');
      await j.makeAheadPass();
      await until(() => made(j, b));
      await big(b);
      await j.makeAheadPass();
      await until(() => !made(j, a));
      expect(await onDisk(tapped), isTrue);
      // Asked for, so kept (the Library holds it); made ahead, it passes
      // through Latest like anything that arrives.
      expect((await db.spineDao.workById((await spokenId(tapped))!))!
          .persistence, 'work');
      expect((await db.spineDao.workById((await spokenId(b))!))!
          .persistence, 'ephemeron');
    });
  });

  test('a kill: it is not on the line a launch restarts, it waits in its '
      'own record and picks up at the first missing stage', () async {
    final j = await started();
    await j.makeAhead!.switchOn(feedId);
    final e = await episode('New');
    held[e.work.id] = Completer<void>();
    await j.makeAheadPass();
    await until(() => making(j, e) && translated == 1);
    await j.saved;
    await j.makeAhead!.saved;

    expect(await db.deviceSettingsDao.read(listenLineKey), isNull,
        reason: 'the line restarts at launch whatever the conditions');

    // A second app, as after the process died with the job half done.
    held.clear();
    final after = await started();
    expect(after.makeAhead!.isWaiting(e.work.id), isTrue);
    await after.makeAheadPass();
    await until(() => made(after, e));
    expect(transcribed, 1, reason: 'the kept transcript is not made again');
  });

  test('a job that fails on its own is tried once more, then left alone',
      () async {
    final failing = ListenChain(
      db: db,
      foreground: gate,
      transcribe: (w, e) async => transcribed++,
      translate: (w, s, t, p) async => null,
      voiceFor: (_, l) async => null,
      audioFileFor: fileOf,
      tempDir: Directory('${dir.path}/tmp'),
    );
    final j = ListenJobs(
      db: db,
      chain: failing,
      languagesFor: ({required workLang, required feedLang}) => const ['fr'],
      downloadsFor: (work, episode, lang) async => const [],
      player: controller,
      inFront: () => true,
      makeAhead: MakeAhead(
          db: db,
          conditionsMet: () async => true,
          modelsNeeded: (w, e, l, {required forShow}) async => const [],
          audioFileFor: fileOf),
    );
    await j.ready;
    await j.resumeLine();
    await j.makeAhead!.switchOn(feedId);
    final e = await episode('New');

    await j.makeAheadPass();
    await until(() => transcribed >= 2);
    await beats();
    await j.makeAheadPass();
    await beats();
    expect(transcribed, 2);
    expect(j.makeAhead!.isWaiting(e.work.id), isFalse);
  });

  test('switched off: what was waiting goes, and nothing new is picked',
      () async {
    final j = await started();
    await j.makeAhead!.switchOn(feedId);
    final e = await episode('New');
    wifiAndCharging = false;
    await j.makeAheadPass();
    await until(() => j.makeAhead!.isWaiting(e.work.id));

    j.makeAhead!.switchOff(feedId);
    wifiAndCharging = true;
    await episode('Newer');
    await j.makeAheadPass();
    await beats();
    expect(transcribed, 0);
    expect(j.makeAhead!.isWaiting(e.work.id), isFalse);

    // On again: it starts from now, so what waited before does not return.
    await j.makeAhead!.switchOn(feedId);
    await j.makeAheadPass();
    await beats();
    expect(transcribed, 0);
  });

  test('a backup restore forgets every show and every pick', () async {
    final j = await started();
    await j.makeAhead!.switchOn(feedId);
    await episode('New');
    wifiAndCharging = false;
    await j.makeAheadPass();
    await beats();

    await j.stopAll();
    await j.makeAhead!.saved;
    expect(j.makeAhead!.isOn(feedId), isFalse);
    final book = await readAheadBook(db);
    expect(book.shows, isEmpty);
    expect(book.entries, isEmpty);
  });

  group('the switch', () {
    late Feed feed;

    setUp(() async {
      feed = (await db.feedsDao.feedById(feedId))!;
    });

    Future<void> pumpSwitch(WidgetTester tester, ListenJobs j) async {
      await tester.pumpWidget(MaterialApp(
          theme: OhTheme.light(),
          home: Scaffold(body: Builder(
              builder: (context) => TextButton(
                  key: const Key('go'),
                  onPressed: () => j.setMakeAhead(context, feed, true),
                  child: const Text('go'))))));
    }

    Future<void> frames(WidgetTester tester, [int n = 8]) async {
      for (var i = 0; i < n; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 15));
        await tester.pump();
      }
    }

    testWidgets('no learning language: the first switch-on asks which',
        (tester) async {
      await tester.runAsync(() async {
        await db.deviceSettingsDao.clear(learningLanguageKey);
        await episode('Old');
        final j = jobs();
        await j.ready;
        expect(j.aheadOfferFor(feed)!.lang, isNull);
        await pumpSwitch(tester, j);
        await tester.tap(find.byKey(const Key('go')));
        await frames(tester);
        expect(find.text('Which language are you learning?'), findsOneWidget);
        await tester.tap(find.byKey(const Key('learning-language-es')));
        await frames(tester);
        expect(j.makeAhead!.isOn(feedId), isTrue);
        expect(j.language, 'es');
      });
    });

    testWidgets('a model to fetch: the same consent sheet, and Not now '
        'leaves the show off', (tester) async {
      await tester.runAsync(() async {
        await episode('Old');
        models = [const DownloadItem('Translator, one time')];
        final j = jobs();
        await j.ready;
        await pumpSwitch(tester, j);

        await tester.tap(find.byKey(const Key('go')));
        await frames(tester);
        expect(find.byKey(const Key('consent-dialog')), findsOneWidget);
        await tester.tap(find.byKey(const Key('consent-cancel')));
        await frames(tester);
        expect(j.makeAhead!.isOn(feedId), isFalse);
      });
    });

    testWidgets('a yes is remembered for that language', (tester) async {
      await tester.runAsync(() async {
        await episode('Old');
        models = [const DownloadItem('Translator, one time')];
        final j = jobs();
        await j.ready;
        await pumpSwitch(tester, j);

        await tester.tap(find.byKey(const Key('go')));
        await frames(tester);
        await tester.tap(find.byKey(const Key('consent-accept')));
        await frames(tester);
        expect(j.makeAhead!.isOn(feedId), isTrue);
        expect(j.makeAhead!.agreedLang(feedId), 'fr');
      });
    });

    test('there is no switch where the show cannot be made in the learning '
        'language', () async {
      final j = ListenJobs(
        db: db,
        chain: chain(gate),
        languagesFor: ({required workLang, required feedLang}) => const ['es'],
        downloadsFor: (work, episode, lang) async => const [],
        makeAhead: MakeAhead(
            db: db,
            conditionsMet: () async => true,
            modelsNeeded: (w, e, l, {required forShow}) async => const [],
            audioFileFor: fileOf),
      );
      await j.ready;
      expect(j.aheadOfferFor(feed), isNull);
    });
  });

  test('wifiAndCharging: both, and an unknown is no', () async {
    expect(await wifiAndChargingOf(metered: false, charging: true), isTrue);
    expect(await wifiAndChargingOf(metered: true, charging: true), isFalse);
    expect(await wifiAndChargingOf(metered: false, charging: false), isFalse);
    expect(await wifiAndCharging_throws(), isFalse);
  });
}

Future<bool> wifiAndChargingOf(
        {required bool metered, required bool charging}) =>
    wifiAndCharging(() async => metered, () async => charging);

// ignore: non_constant_identifier_names
Future<bool> wifiAndCharging_throws() =>
    wifiAndCharging(() async => throw StateError('no'), () async => true);
