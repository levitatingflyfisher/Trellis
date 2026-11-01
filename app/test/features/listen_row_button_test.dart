import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhearth_design/openhearth_design.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/listen/listen_chain.dart';
import 'package:trellis/features/listen/listen_jobs.dart';
import 'package:trellis/features/listen/listen_row_button.dart';
import 'package:trellis/features/models/consent.dart';
import 'package:trellis/features/player/player_controller.dart';
import 'package:trellis/features/reader/speech/speech_engine.dart';
import 'package:trellis/features/works/work_row.dart';

import '../support/fake_player.dart';
import '../support/fake_services.dart';

typedef _Ep = ({Work work, Episode episode});

/// The second button on an episode's row (1.6.x, owner: "I click play on
/// it and then I listen to it in my learning language"): Play stays as it
/// is; beside it the learning language, which is made on one tap, shows
/// how far it is, and plays when it is ready. Where it cannot be made
/// there is no button.
void main() {
  late Directory dir;
  late AppDatabase db;
  late int profileId;
  late int feedId;
  late FakeEpisodePlayer player;
  late PlayerController controller;
  late List<DownloadItem> downloads;
  late int transcribed;
  late bool inFront;
  late RecordingForegroundGate gate;

  /// A work whose translation waits here, part done, until completed.
  late Map<int, Completer<void>> held;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('trellis-listen-row');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.profilesDao.create('Ada');
    feedId = await db.feedsDao.insertFeed(
        profileId: profileId, url: 'https://cast.test/feed', title: 'Show');
    player = FakeEpisodePlayer();
    controller = PlayerController(
        db: db, profileId: profileId, createPlayer: () => player);
    downloads = [];
    transcribed = 0;
    inFront = true;
    held = {};
    gate = RecordingForegroundGate();
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
    dir.deleteSync(recursive: true);
  });

  var serial = 0;
  Future<_Ep> episode(String title,
      {String? lang = 'en',
      bool audio = true,
      String? guid,
      String kind = 'episode'}) async {
    final n = ++serial;
    final id = await db.spineDao.insertWork(
        profileId: profileId,
        kind: kind,
        title: title,
        persistence: 'ephemeron',
        firstSeenEpochDay: 100,
        sourceUrl: 'https://cast.test/$n.mp3',
        lang: lang);
    await db.feedsDao.insertEpisode(
        workId: id,
        feedId: feedId,
        guid: guid ?? 'g$n',
        enclosureUrl: audio ? 'https://cast.test/$n.mp3' : null,
        publishedAtMs: 5000 + n);
    return (
      work: (await db.spineDao.workById(id))!,
      episode: (await db.feedsDao.episodeOf(id))!,
    );
  }

  ListenChain chain() => ListenChain(
        db: db,
        foreground: gate,
        transcribe: (w, e) async {
          transcribed++;
          await db.spineDao.insertSegments(
              w.id, const [(idx: 0, kind: 'prose', text: 'Hello there.')]);
          await db.spineDao.insertAlignments(
              w.id, const [(segmentIdx: 0, tStartMs: 0, tEndMs: 2000)]);
        },
        translate: (w, source, target, progress) async {
          progress(2, 5);
          await held[w.id]?.future;
          await db.spineDao.upsertTranslationSentence(
              workId: w.id,
              segmentIdx: 0,
              sentenceIdx: 0,
              lang: target,
              sourceText: 'Hello there.',
              body: 'Hola.');
          return null;
        },
        voiceFor: (_, lang) async => (
          name: 'Test voice',
          say: (String t) async =>
              SynthResult(samples: Float32List(100), sampleRate: 1000),
        ),
        audioFileFor: testServices(dir).audioFileFor,
        tempDir: Directory('${dir.path}/tmp'),
      );

  /// Every language in [can] but the episode's own, as the device's rule
  /// gives it.
  ListenJobs jobs(
          {ListenChain? over, List<String> can = const ['es', 'fr']}) =>
      ListenJobs(
        db: db,
        chain: over ?? chain(),
        languagesFor: ({required workLang, required feedLang}) => [
          for (final l in can)
            if (l != (workLang ?? feedLang ?? 'en')) l,
        ],
        downloadsFor: (work, episode, lang) async => downloads,
        player: controller,
        inFront: () => inFront,
      );

  Widget rowOf(ListenJobs? j, _Ep e, {bool read = false}) => WorkRow(
        work: e.work,
        episode: e.episode,
        facts: WorkRowFacts(audio: true, transcribed: read),
        showTitle: 'Show',
        onPlay: () {},
        onRead: read ? () {} : null,
        second: j == null
            ? null
            : ListenRowButton(jobs: j, work: e.work, episode: e.episode),
        menuBuilder: (_) => const [
          PopupMenuItem(value: 'x', child: Text('Something')),
        ],
        onMenu: (_) {},
      );

  Future<void> pumpRows(WidgetTester tester, ListenJobs? j, List<_Ep> eps,
      {double width = 412, double scale = 1.0, bool read = false}) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await tester.pumpWidget(MaterialApp(
        theme: OhTheme.light(),
        home: Scaffold(
            body: ListView(
                children: [for (final e in eps) rowOf(j, e, read: read)]))));
    await tester.pump();
  }

  /// Real time for the chain's file work, a frame after each wait.
  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 150 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
    }
    await tester.pump();
  }

  Future<void> beats(WidgetTester tester, [int n = 8]) async {
    for (var i = 0; i < n; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
    }
  }

  Finder button(_Ep e) => find.byKey(Key('listen-${e.work.id}'));

  Future<int?> spokenOf(_Ep e, [String lang = 'es']) async =>
      (await (db.select(db.episodes)
                ..where((r) => r.guid.equals('spoken:${e.work.id}:$lang')))
              .getSingleOrNull())
          ?.workId;

  group('make it', () {
    testWidgets('no learning language yet: the button is a translate glyph, '
        'the first tap asks which language, then goes on and plays it',
        (tester) async {
      await tester.runAsync(() async {
        final e = await episode('Harbour');
        final j = jobs();
        await j.ready;
        await pumpRows(tester, j, [e]);

        expect(button(e), findsOneWidget);
        expect(
            find.descendant(
                of: button(e), matching: find.byIcon(Icons.translate)),
            findsOneWidget);
        expect(find.byTooltip('Listen in another language'), findsOneWidget);

        await tester.tap(button(e));
        await beats(tester);
        expect(find.text('Which language are you learning?'), findsOneWidget);
        await tester.tap(find.byKey(const Key('learning-language-es')));
        await until(tester, () => controller.current != null);

        expect(await db.deviceSettingsDao.read(learningLanguageKey), 'es');
        expect(controller.current?.id, await spokenOf(e));
        expect(transcribed, 1);
        // It never left the list.
        expect(find.byType(WorkRow), findsOneWidget);
        expect(find.byTooltip('Play in Spanish'), findsOneWidget);
      });
    });

    testWidgets('with the language known the button names it, and one tap '
        'makes the episode with no question and plays it when ready',
        (tester) async {
      await tester.runAsync(() async {
        await db.deviceSettingsDao.write(learningLanguageKey, 'fr');
        final e = await episode('Harbour');
        final j = jobs();
        await j.ready;
        await pumpRows(tester, j, [e]);

        expect(find.descendant(of: button(e), matching: find.text('French')),
            findsOneWidget);
        expect(find.byTooltip('Listen in French'), findsOneWidget);
        expect(find.bySemanticsLabel('Listen in French'), findsOneWidget);

        await tester.tap(button(e));
        await until(tester, () => controller.current != null);

        expect(find.text('Which language are you learning?'), findsNothing);
        expect(controller.current?.id, await spokenOf(e, 'fr'));
        expect(find.textContaining('Playing “Harbour'), findsOneWidget);
      });
    });

    testWidgets('the question offers exactly the languages this episode '
        'can be made in, by their plain names; dismissed, nothing starts',
        (tester) async {
      await tester.runAsync(() async {
        final e = await episode('Puerto', lang: 'es');
        final j = jobs(can: const ['en', 'es', 'fr', 'pt']);
        await j.ready;
        await pumpRows(tester, j, [e]);

        await tester.tap(button(e));
        await beats(tester);

        expect(
            tester
                .widgetList<Text>(find.descendant(
                    of: find.byType(SimpleDialogOption),
                    matching: find.byType(Text)))
                .map((t) => t.data),
            ['English', 'French', 'Portuguese']);
        expect(find.textContaining('can make this episode in'), findsOneWidget);

        await tester.tapAt(const Offset(5, 5));
        await beats(tester);
        expect(transcribed, 0);
        expect(await db.deviceSettingsDao.read(learningLanguageKey), isNull);
        expect(find.byTooltip('Listen in another language'), findsOneWidget);
      });
    });

    testWidgets('what it would download is agreed to first; a no starts '
        'nothing', (tester) async {
      await tester.runAsync(() async {
        await db.deviceSettingsDao.write(learningLanguageKey, 'es');
        downloads = const [
          DownloadItem('English to Spanish translator, 115 MB'),
        ];
        final e = await episode('Harbour');
        final j = jobs();
        await j.ready;
        await pumpRows(tester, j, [e]);

        await tester.tap(button(e));
        await beats(tester);
        expect(find.byKey(const Key('consent-dialog')), findsOneWidget);
        await tester.tap(find.text('Not now'));
        await beats(tester);

        expect(transcribed, 0);
        expect(controller.current, isNull);
        expect(find.byTooltip('Listen in Spanish'), findsOneWidget);
      });
    });
  });

  group('making it', () {
    testWidgets('the button shows the stage and how far it is',
        (tester) async {
      await tester.runAsync(() async {
        await db.deviceSettingsDao.write(learningLanguageKey, 'es');
        final e = await episode('Harbour');
        held[e.work.id] = Completer<void>();
        final j = jobs();
        await j.ready;
        await pumpRows(tester, j, [e]);

        await tester.tap(button(e));
        await beats(tester);

        expect(
            find.descendant(of: button(e), matching: find.text('Spanish 40%')),
            findsOneWidget);
        final ring = tester.widget<CircularProgressIndicator>(find.descendant(
            of: button(e), matching: find.byType(CircularProgressIndicator)));
        expect(ring.value, closeTo(0.4, 0.001));
        expect(find.byTooltip('Making it in Spanish: translating, 40%'),
            findsOneWidget);
        expect(find.bySemanticsLabel('Making it in Spanish: translating, 40%'),
            findsOneWidget);

        held[e.work.id]!.complete();
        await until(tester, () => controller.current != null);
      });
    });

    testWidgets('the progress is the shared job’s, not the row’s: it is '
        'still there after the row leaves the screen and the list is left '
        'and opened again', (tester) async {
      await tester.runAsync(() async {
        await db.deviceSettingsDao.write(learningLanguageKey, 'es');
        final e = await episode('Harbour');
        held[e.work.id] = Completer<void>();
        final j = jobs();
        await j.ready;
        await pumpRows(tester, j, [e]);
        await tester.tap(button(e));
        await beats(tester);
        expect(find.text('Spanish 40%'), findsOneWidget);

        // The list is gone: another page stands where it was.
        await tester.pumpWidget(const MaterialApp(home: Text('Elsewhere')));
        await beats(tester, 3);
        expect(button(e), findsNothing);

        // Back: new row widgets, the same job.
        await pumpRows(tester, j, [e]);
        expect(find.text('Spanish 40%'), findsOneWidget);
        expect(find.byTooltip('Making it in Spanish: translating, 40%'),
            findsOneWidget);

        held[e.work.id]!.complete();
        await until(tester, () => controller.current != null);
        expect(controller.current?.id, await spokenOf(e));
      });
    });

    testWidgets('a tap while it is made offers Stop; stopped, the button '
        'offers to make it again', (tester) async {
      await tester.runAsync(() async {
        await db.deviceSettingsDao.write(learningLanguageKey, 'es');
        final e = await episode('Harbour');
        held[e.work.id] = Completer<void>();
        final j = jobs();
        await j.ready;
        await pumpRows(tester, j, [e]);
        await tester.tap(button(e));
        await beats(tester);

        await tester.tap(button(e));
        await beats(tester);
        expect(find.byKey(const Key('listen-stop-dialog')), findsOneWidget);
        expect(find.textContaining('Translating into Spanish'), findsOneWidget);
        await tester.tap(find.byKey(const Key('listen-stop')));
        await beats(tester);
        // It stops at the next sentence.
        held[e.work.id]!.complete();
        await until(tester,
            () => find.byTooltip('Listen in Spanish').evaluate().isNotEmpty);

        expect(find.byTooltip('Listen in Spanish'), findsOneWidget);
        expect(controller.current, isNull);
        expect(await spokenOf(e), isNull);
      });
    });

    testWidgets('a second episode tapped while one is being made waits its '
        'turn and says so; it is made when the first is done',
        (tester) async {
      await tester.runAsync(() async {
        await db.deviceSettingsDao.write(learningLanguageKey, 'es');
        final a = await episode('Harbour');
        final b = await episode('Lighthouse');
        held[a.work.id] = Completer<void>();
        final j = jobs();
        await j.ready;
        await pumpRows(tester, j, [a, b]);

        await tester.tap(button(a));
        await beats(tester);
        await tester.tap(button(b));
        await beats(tester);

        expect(
            find.text('One is already being made: “Harbour”. This one '
                'waits its turn.'),
            findsOneWidget);
        expect(find.byTooltip('Waiting to be made in Spanish'), findsOneWidget);
        expect(
            find.descendant(
                of: button(b), matching: find.byIcon(Icons.hourglass_empty)),
            findsOneWidget);
        expect(transcribed, 1, reason: 'only the first has started');
        // The second holds the app awake from its own tap: Android would
        // refuse it later, from behind a dark screen.
        expect(gate.events, contains('start:Lighthouse'));

        held[a.work.id]!.complete();
        await until(tester, () => transcribed == 2);
        expect(await spokenOf(a), isNotNull);
        Future<bool> bothMade() async => await spokenOf(b) != null;
        for (var i = 0; i < 150 && !await bothMade(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
        await beats(tester);

        expect(await spokenOf(b), isNotNull);
        expect(find.byTooltip('Play in Spanish'), findsNWidgets(2));
        // The first played when it was ready; the second does not cut in.
        expect(controller.current?.id, await spokenOf(a));
        expect(
            gate.events.where((e) => e.startsWith('start')).length,
            gate.events.where((e) => e == 'finished').length,
            reason: 'every hold taken is let go: ${gate.events}');
      });
    });

    testWidgets('a waiting episode can be taken out of the line',
        (tester) async {
      await tester.runAsync(() async {
        await db.deviceSettingsDao.write(learningLanguageKey, 'es');
        final a = await episode('Harbour');
        final b = await episode('Lighthouse');
        held[a.work.id] = Completer<void>();
        final j = jobs();
        await j.ready;
        await pumpRows(tester, j, [a, b]);
        await tester.tap(button(a));
        await beats(tester);
        await tester.tap(button(b));
        await beats(tester);

        await tester.tap(button(b));
        await beats(tester);
        await tester.tap(find.byKey(const Key('listen-stop')));
        await beats(tester);
        held[a.work.id]!.complete();
        await until(tester, () => controller.current != null);
        await beats(tester);

        expect(transcribed, 1);
        expect(await spokenOf(b), isNull);
      });
    });
  });

  group('ready', () {
    testWidgets('one tap plays the made episode at once and makes nothing',
        (tester) async {
      await tester.runAsync(() async {
        await db.deviceSettingsDao.write(learningLanguageKey, 'es');
        final e = await episode('Harbour');
        final c = chain();
        final made = await c.start(e.work, 'es');
        final j = jobs(over: c);
        await j.ready;
        await pumpRows(tester, j, [e]);

        expect(find.byTooltip('Play in Spanish'), findsOneWidget);
        expect(find.bySemanticsLabel('Play in Spanish'), findsOneWidget);
        expect(
            find.descendant(
                of: button(e), matching: find.byIcon(Icons.play_circle)),
            findsOneWidget);

        await tester.tap(button(e));
        await until(tester, () => controller.current != null);

        expect(controller.current?.id, made);
        expect(transcribed, 1);
      });
    });

    testWidgets('a made episode whose audio was deleted is offered to be '
        'made again, not played', (tester) async {
      await tester.runAsync(() async {
        await db.deviceSettingsDao.write(learningLanguageKey, 'es');
        final e = await episode('Harbour');
        final c = chain();
        final made = (await c.start(e.work, 'es'))!;
        final url = (await db.feedsDao.episodeOf(made))!.enclosureUrl!;
        testServices(dir).audioFileFor(made, url).deleteSync();
        final j = jobs(over: c);
        await j.ready;
        await pumpRows(tester, j, [e]);

        expect(find.byTooltip('Listen in Spanish'), findsOneWidget);
      });
    });

    testWidgets('a job that ends while something else plays does not cut '
        'in: it says the episode is ready, and the button plays it',
        (tester) async {
      await tester.runAsync(() async {
        await db.deviceSettingsDao.write(learningLanguageKey, 'es');
        final e = await episode('Harbour');
        final other = await episode('Lighthouse');
        held[e.work.id] = Completer<void>();
        final j = jobs();
        await j.ready;
        await pumpRows(tester, j, [e]);
        await tester.tap(button(e));
        await beats(tester);
        await controller.playWork(other.work);
        expect(controller.playing, isTrue);

        held[e.work.id]!.complete();
        await until(tester,
            () => find.byTooltip('Play in Spanish').evaluate().isNotEmpty);
        await beats(tester);

        expect(controller.current?.id, other.work.id);
        expect(find.textContaining('“Harbour (Spanish)” is ready'),
            findsOneWidget);
      });
    });

    testWidgets('nor does it start playing from behind another app',
        (tester) async {
      await tester.runAsync(() async {
        await db.deviceSettingsDao.write(learningLanguageKey, 'es');
        final e = await episode('Harbour');
        held[e.work.id] = Completer<void>();
        final j = jobs();
        await j.ready;
        await pumpRows(tester, j, [e]);
        await tester.tap(button(e));
        await beats(tester);
        inFront = false;

        held[e.work.id]!.complete();
        await until(tester,
            () => find.byTooltip('Play in Spanish').evaluate().isNotEmpty);
        await beats(tester);

        expect(controller.current, isNull);
      });
    });
  });

  group('after the app was killed', () {
    Future<void> seedLine(List<_Ep> eps, [String lang = 'es']) =>
        db.deviceSettingsDao.write(
            listenLineKey,
            jsonEncode([
              for (final e in eps) {'workId': e.work.id, 'lang': lang},
            ]));

    Future<List<int>?> line() async {
      final raw = await db.deviceSettingsDao.read(listenLineKey);
      if (raw == null) return null;
      return [
        for (final m in jsonDecode(raw) as List)
          (m as Map<String, dynamic>)['workId'] as int,
      ];
    }

    testWidgets('what was asked for is written down, in line order, and '
        'gone when it finishes', (tester) async {
      await tester.runAsync(() async {
        await db.deviceSettingsDao.write(learningLanguageKey, 'es');
        final a = await episode('Harbour');
        final b = await episode('Lighthouse');
        held[a.work.id] = Completer<void>();
        final j = jobs();
        await j.ready;
        await pumpRows(tester, j, [a, b]);
        await tester.tap(button(a));
        await beats(tester);
        await tester.tap(button(b));
        await beats(tester);
        await j.saved;

        expect(await line(), [a.work.id, b.work.id]);

        held[a.work.id]!.complete();
        await until(tester,
            () => find.byTooltip('Play in Spanish').evaluate().length == 2);
        await beats(tester);
        await j.saved;
        expect(await line(), isNull);
      });
    });

    testWidgets('a job that was under way is picked up: the row says it is '
        'being made, the chain carries on, and the end does not play it',
        (tester) async {
      await tester.runAsync(() async {
        await db.deviceSettingsDao.write(learningLanguageKey, 'es');
        final e = await episode('Harbour');
        await seedLine([e]);
        held[e.work.id] = Completer<void>();
        final j = jobs();
        await j.ready;
        await pumpRows(tester, j, [e]);

        // The record alone already says it is on its way.
        expect(find.byTooltip('Waiting to be made in Spanish'), findsOneWidget);

        await j.resumeLine();
        await beats(tester);
        expect(find.byTooltip('Making it in Spanish: translating, 40%'),
            findsOneWidget);
        expect(transcribed, 1);

        held[e.work.id]!.complete();
        await until(tester,
            () => find.byTooltip('Play in Spanish').evaluate().isNotEmpty);
        await beats(tester);

        expect(find.byTooltip('Play in Spanish'), findsOneWidget);
        expect(controller.current, isNull,
            reason: 'nobody tapped since the restart');
        await j.saved;
        expect(await line(), isNull);
      });
    });

    testWidgets('a line keeps its order, and the one behind holds the app '
        'awake from the launch', (tester) async {
      await tester.runAsync(() async {
        await db.deviceSettingsDao.write(learningLanguageKey, 'es');
        final a = await episode('Harbour');
        final b = await episode('Lighthouse');
        await seedLine([a, b]);
        held[a.work.id] = Completer<void>();
        final j = jobs();
        await j.ready;
        await pumpRows(tester, j, [a, b]);
        await j.resumeLine();
        await beats(tester);

        expect(find.byTooltip('Making it in Spanish: translating, 40%'),
            findsOneWidget);
        expect(find.byTooltip('Waiting to be made in Spanish'), findsOneWidget);
        expect(transcribed, 1);
        expect(gate.events, contains('start:Lighthouse'));

        held[a.work.id]!.complete();
        await until(tester,
            () => find.byTooltip('Play in Spanish').evaluate().length == 2);
        await beats(tester);

        expect(transcribed, 2);
        expect(controller.current, isNull);
        expect(
            gate.events.where((e) => e.startsWith('start')).length,
            gate.events.where((e) => e == 'finished').length,
            reason: 'every hold taken is let go: ${gate.events}');
      });
    });

    testWidgets('with nothing written down it starts nothing, and a second '
        'call changes nothing', (tester) async {
      await tester.runAsync(() async {
        await db.deviceSettingsDao.write(learningLanguageKey, 'es');
        final e = await episode('Harbour');
        final j = jobs();
        await j.ready;
        await pumpRows(tester, j, [e]);

        await j.resumeLine();
        await j.resumeLine();
        await beats(tester);

        expect(transcribed, 0);
        expect(find.byTooltip('Listen in Spanish'), findsOneWidget);
      });
    });

    testWidgets('Stop takes it off the record at once, before the job has '
        'wound down', (tester) async {
      await tester.runAsync(() async {
        await db.deviceSettingsDao.write(learningLanguageKey, 'es');
        final e = await episode('Harbour');
        await seedLine([e]);
        held[e.work.id] = Completer<void>();
        final j = jobs();
        await j.ready;
        await pumpRows(tester, j, [e]);
        await j.resumeLine();
        await beats(tester);

        await tester.tap(button(e));
        await beats(tester);
        await tester.tap(find.byKey(const Key('listen-stop')));
        await beats(tester);
        await j.saved;

        expect(await line(), isNull,
            reason: 'a kill now must not bring back a stopped job');

        held[e.work.id]!.complete();
        await until(tester,
            () => find.byTooltip('Listen in Spanish').evaluate().isNotEmpty);
        expect(await spokenOf(e), isNull);
      });
    });

    testWidgets('Stop before the line has come back keeps it from coming '
        'back', (tester) async {
      await tester.runAsync(() async {
        await db.deviceSettingsDao.write(learningLanguageKey, 'es');
        final e = await episode('Harbour');
        await seedLine([e]);
        final j = jobs();
        await j.ready;
        await pumpRows(tester, j, [e]);

        await tester.tap(button(e));
        await beats(tester);
        await tester.tap(find.byKey(const Key('listen-stop')));
        await beats(tester);
        await j.saved;
        await j.resumeLine();
        await beats(tester);

        expect(await line(), isNull);
        expect(transcribed, 0);
      });
    });

    testWidgets('a failure takes it off the record', (tester) async {
      await tester.runAsync(() async {
        await db.deviceSettingsDao.write(learningLanguageKey, 'es');
        // In Spanish already, so the chain stops with a reason.
        final e = await episode('Puerto', lang: 'es');
        await seedLine([e]);
        final j = jobs();
        await j.ready;
        await j.resumeLine();
        for (var i = 0; i < 50 && await line() != null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await j.saved;
        }

        expect(await line(), isNull);
        expect(j.chain.stateOf(e.work.id)?.stage, ListenStage.failed);
      });
    });

    testWidgets('an episode deleted since is dropped and the rest go on',
        (tester) async {
      await tester.runAsync(() async {
        await db.deviceSettingsDao.write(learningLanguageKey, 'es');
        final e = await episode('Harbour');
        await db.deviceSettingsDao.write(
            listenLineKey,
            jsonEncode([
              {'workId': 987654, 'lang': 'es'},
              {'workId': e.work.id, 'lang': 'es'},
            ]));
        final j = jobs();
        await j.ready;
        await pumpRows(tester, j, [e]);
        await j.resumeLine();
        await until(tester,
            () => find.byTooltip('Play in Spanish').evaluate().isNotEmpty);

        expect(transcribed, 1);
        await j.saved;
        expect(await line(), isNull);
      });
    });

    test('a record that cannot be read is set aside and nothing starts',
        () async {
      await db.deviceSettingsDao.write(listenLineKey, 'not json {');
      final j = jobs();
      await j.ready;
      await j.resumeLine();
      await j.saved;

      expect(await db.deviceSettingsDao.read(listenLineKey), isNull);
      expect(await db.deviceSettingsDao.read('$listenLineKey-unreadable'),
          'not json {');
      expect(transcribed, 0);
    });

    testWidgets('a tap on another episode before the line comes back does '
        'not lose what was written down', (tester) async {
      await tester.runAsync(() async {
        await db.deviceSettingsDao.write(learningLanguageKey, 'es');
        final a = await episode('Harbour');
        final b = await episode('Lighthouse');
        await seedLine([a]);
        held[b.work.id] = Completer<void>();
        final j = jobs();
        await j.ready;
        await pumpRows(tester, j, [a, b]);

        await tester.tap(button(b));
        await beats(tester);
        await j.saved;
        expect(await line(), [b.work.id, a.work.id]);

        await j.resumeLine();
        held[b.work.id]!.complete();
        await until(tester,
            () => find.byTooltip('Play in Spanish').evaluate().length == 2);
        await beats(tester);
        expect(transcribed, 2);
      });
    });

    testWidgets('before a backup restore everything stops and the record '
        'goes: the ids are about to mean other episodes', (tester) async {
      await tester.runAsync(() async {
        await db.deviceSettingsDao.write(learningLanguageKey, 'es');
        final a = await episode('Harbour');
        final b = await episode('Lighthouse');
        await seedLine([a, b]);
        held[a.work.id] = Completer<void>();
        final j = jobs();
        await j.ready;
        await pumpRows(tester, j, [a, b]);
        await j.resumeLine();
        await beats(tester);

        final stopping = j.stopAll();
        held[a.work.id]!.complete();
        await stopping;
        await beats(tester);

        expect(await line(), isNull);
        expect(transcribed, 1, reason: 'the one behind never started');
        expect(find.byTooltip('Listen in Spanish'), findsNWidgets(2));
      });
    });
  });

  group('absent, not dead', () {
    testWidgets('there is no button where the episode cannot be made in '
        'the learning language, and the row is laid out as it was',
        (tester) async {
      await tester.runAsync(() async {
        await db.deviceSettingsDao.write(learningLanguageKey, 'es');
        final spanish = await episode('Puerto', lang: 'es');
        final j = jobs();
        await j.ready;

        await pumpRows(tester, null, [spanish]);
        final plain = tester.getRect(find.byKey(Key('play-${spanish.work.id}')));
        final height = tester.getSize(find.byType(WorkRow)).height;

        await pumpRows(tester, j, [spanish]);
        expect(button(spanish), findsNothing);
        expect(tester.getRect(find.byKey(Key('play-${spanish.work.id}'))),
            plain);
        expect(tester.getSize(find.byType(WorkRow)).height, height);
      });
    });

    test('each reason for no button', () async {
      await db.deviceSettingsDao.write(learningLanguageKey, 'es');
      final english = await episode('Harbour');
      final spanish = await episode('Puerto', lang: 'es');
      final text = await episode('Field notes', audio: false);
      final spoken = await episode('Harbour (Spanish)',
          lang: 'es', guid: 'spoken:${english.work.id}:es');
      final book = await episode('A book read aloud', kind: 'audiobook');

      final j = jobs();
      // Before the learning language has been read, nothing is offered:
      // a button must not appear and then go.
      expect(j.offerFor(english.work, english.episode), isNull);
      await j.ready;

      expect(j.offerFor(english.work, english.episode)?.lang, 'es');
      expect(j.offerFor(spanish.work, spanish.episode), isNull,
          reason: 'already in that language');
      expect(j.offerFor(text.work, text.episode), isNull,
          reason: 'a text item');
      expect(j.offerFor(english.work, null), isNull,
          reason: 'not from a feed');
      expect(j.offerFor(spoken.work, spoken.episode), isNull,
          reason: 'itself a spoken translation');
      expect(j.offerFor(book.work, book.episode), isNull,
          reason: 'an audiobook');

      // No translator route or no voice: nothing can be made at all.
      final none = jobs(can: const []);
      await none.ready;
      expect(none.offerFor(english.work, english.episode), isNull);

      // A language is chosen, and this device cannot make it.
      await db.deviceSettingsDao.write(learningLanguageKey, 'de');
      final german = jobs();
      await german.ready;
      expect(german.offerFor(english.work, english.episode), isNull);
    });

    test('the show’s language stands in for an episode that names none',
        () async {
      await db.deviceSettingsDao.write(learningLanguageKey, 'es');
      final e = await episode('Puerto', lang: null);
      final j = jobs();
      await j.ready;

      expect(j.offerFor(e.work, e.episode, feedLang: 'es'), isNull);
      expect(j.offerFor(e.work, e.episode, feedLang: 'en')?.lang, 'es');
    });
  });

  group('in a narrow row', () {
    const long = 'Wild Horse Nine: the long conversation about a film that '
        'nobody expected to be made, part two of three';

    testWidgets('at 320dp with a long title every state fits, is at least '
        '48 by 48, and says the language by its short code',
        (tester) async {
      await tester.runAsync(() async {
        await db.deviceSettingsDao.write(learningLanguageKey, 'pt');
        final making = await episode(long);
        final waiting = await episode('$long, again');
        final c = chain();
        final ready = await episode('Ready: $long');
        await c.start(ready.work, 'pt');
        held[making.work.id] = Completer<void>();
        final j = jobs(over: c, can: const ['es', 'fr', 'pt']);
        await j.ready;
        final fresh = await episode('Fresh: $long');

        for (final scale in [1.0, 1.3, 2.0]) {
          await pumpRows(tester, j, [fresh, making, waiting, ready],
              width: 320, scale: scale, read: true);
          if (scale == 1.0) {
            await tester.tap(button(making));
            await beats(tester);
            await tester.tap(button(waiting));
            await beats(tester);
            ScaffoldMessenger.of(tester.element(find.byType(ListView)))
                .clearSnackBars();
            await beats(tester, 2);
          }
          expect(tester.takeException(), isNull, reason: 'at $scale');
          for (final e in [fresh, making, waiting, ready]) {
            final size = tester.getSize(button(e));
            expect(size.width, greaterThanOrEqualTo(48), reason: '$scale');
            expect(size.height, greaterThanOrEqualTo(48), reason: '$scale');
            final rect = tester.getRect(button(e));
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(320));
          }
          expect(find.descendant(of: button(fresh), matching: find.text('PT')),
              findsOneWidget);
          expect(
              find.descendant(
                  of: button(making), matching: find.text('PT 40%')),
              findsOneWidget);
          expect(find.text('Portuguese'), findsNothing);
        }

        held[making.work.id]!.complete();
        await until(tester, () => transcribed == 3);
        await beats(tester, 20);
      });
    });

    testWidgets('on a 360dp phone Play, the language and the menu share one '
        'line', (tester) async {
      await tester.runAsync(() async {
        await db.deviceSettingsDao.write(learningLanguageKey, 'pt');
        final e = await episode(long);
        final j = jobs(can: const ['pt']);
        await j.ready;
        await pumpRows(tester, j, [e], width: 360);

        final play = tester.getCenter(find.byKey(Key('play-${e.work.id}')));
        final second = tester.getCenter(button(e));
        final menu = tester.getCenter(find.byKey(Key('menu-${e.work.id}')));
        expect(second.dy, play.dy);
        expect(menu.dy, play.dy);
        expect(play.dx, lessThan(second.dx));
        expect(second.dx, lessThan(menu.dx));
      });
    });
  });
}
