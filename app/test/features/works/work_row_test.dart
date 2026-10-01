import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhearth_design/openhearth_design.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/works/work_row.dart';

/// ADR-0016 section 1, widened to every work in 1.5.4: a row that says
/// what state the work is in, the same way on every list.
void main() {
  final published = DateTime(2026, 8, 5).millisecondsSinceEpoch;

  Work work({String title = 'Aurora season'}) => Work(
      id: 7,
      profileId: 1,
      kind: 'episode',
      title: title,
      sourceUrl: 'https://cast.test/aurora.mp3',
      persistence: 'ephemeron',
      firstSeenEpochDay: 100,
      pinned: false,
      showTranslationLayer: false);

  Episode episode({int? durationMs, int? finishedAtMs}) => Episode(
      workId: 7,
      feedId: 1,
      guid: 'g',
      enclosureUrl: 'https://cast.test/aurora.mp3',
      durationMs: durationMs,
      publishedAtMs: published,
      finishedAtMs: finishedAtMs);

  Widget row(WorkRowFacts facts,
          {String? show = 'Night Sky', String title = 'Aurora season'}) =>
      WorkRow(
        work: work(title: title),
        episode: episode(),
        facts: facts,
        showTitle: show,
        onPlay: () {},
        menuBuilder: (_) => const [
          PopupMenuItem(value: 'x', child: Text('Something')),
        ],
        onMenu: (_) {},
      );

  Future<void> pump(WidgetTester tester, Widget child,
      {ThemeData? theme}) async {
    await tester.pumpWidget(MaterialApp(
        theme: theme ?? OhTheme.light(),
        home: Scaffold(body: ListView(children: [child]))));
  }

  group('WorkRowFacts', () {
    test('a position short of the end, not played, is in progress', () {
      const f = WorkRowFacts(durationMs: 600000, progressMs: 150000);
      expect(f.inProgress, isTrue);
      expect(f.fraction, 0.25);
      expect(f.leftMs, 450000);
    });

    test('a played episode is never in progress, wherever it stopped', () {
      const f = WorkRowFacts(
          durationMs: 600000, progressMs: 150000, played: true);
      expect(f.inProgress, isFalse);
    });

    test('no position, or none past the start, is not in progress', () {
      expect(const WorkRowFacts(durationMs: 600000).inProgress, isFalse);
      expect(
          const WorkRowFacts(durationMs: 600000, progressMs: 0).inProgress,
          isFalse);
    });

    test('a position with no known length is in progress without a bar',
        () {
      const f = WorkRowFacts(progressMs: 150000);
      expect(f.inProgress, isTrue);
      expect(f.fraction, isNull);
      expect(f.leftMs, isNull);
    });

    test('of() reads the list state for this episode', () {
      final state = WorkListState(
          queued: {7}, progressMs: {7: 1000}, transcribed: {7});
      final f = WorkRowFacts.of(
          work(), episode(durationMs: 600000, finishedAtMs: 5), state,
          downloaded: true);
      expect(f.queued, isTrue);
      expect(f.transcribed, isTrue);
      expect(f.downloaded, isTrue);
      expect(f.played, isTrue);
      expect(f.isNew, isTrue, reason: 'readAtMs is null');
      expect(f.progressMs, 1000);
      expect(f.durationMs, 600000);
    });

    test('a video enclosure is recognised by its file type', () {
      expect(isVideoEnclosure('https://x.test/ep.mp4'), isTrue);
      expect(isVideoEnclosure('https://x.test/ep.M4V?token=1'), isTrue);
      expect(isVideoEnclosure('https://x.test/ep.mp3'), isFalse);
      expect(isVideoEnclosure(null), isFalse);
    });
  });

  testWidgets('every row that knows its length says it', (tester) async {
    await pump(tester, row(const WorkRowFacts(durationMs: 45 * 60000)));
    expect(find.text('Night Sky · 5 Aug · 45\u00A0min'), findsOneWidget);
  });

  testWidgets('on the podcast page the show name is left out',
      (tester) async {
    await pump(tester,
        row(const WorkRowFacts(durationMs: 45 * 60000), show: null));
    expect(find.text('5 Aug · 45\u00A0min'), findsOneWidget);
  });

  testWidgets('an episode in progress shows a thin bar and the time left',
      (tester) async {
    await pump(
        tester,
        row(const WorkRowFacts(
            durationMs: 45 * 60000, progressMs: 22 * 60000)));
    expect(find.text('Night Sky · 5 Aug · 23\u00A0min\u00A0left'), findsOneWidget);
    final bar = tester
        .widget<LinearProgressIndicator>(find.byKey(const Key('progress-7')));
    expect(bar.value, closeTo(22 / 45, 0.001));
  });

  testWidgets('an unplayed, untouched episode has no bar', (tester) async {
    await pump(tester, row(const WorkRowFacts(durationMs: 45 * 60000)));
    expect(find.byKey(const Key('progress-7')), findsNothing);
    expect(find.byKey(const Key('played-7')), findsNothing);
  });

  testWidgets('markers are words, not just colours', (tester) async {
    await pump(
        tester,
        row(const WorkRowFacts(
            isNew: true,
            downloaded: true,
            queued: true,
            transcribed: true,
            video: true,
            kept: true)));
    for (final label in [
      'New',
      'Downloaded',
      'In Queue',
      'Transcript',
      'Video',
      'Kept'
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.byKey(const Key('unread-dot-7')), findsOneWidget);
    expect(find.byKey(const Key('downloaded-7')), findsOneWidget);
  });

  testWidgets('a row with nothing to say carries no markers',
      (tester) async {
    await pump(tester, row(const WorkRowFacts()));
    for (final label in [
      'New',
      'Downloaded',
      'In Queue',
      'Transcript',
      'Video',
      'Kept',
      'Pinned'
    ]) {
      expect(find.text(label), findsNothing, reason: label);
    }
  });

  group('played rows fade but stay legible', () {
    for (final entry in {
      'light': OhTheme.light(),
      'dark': OhTheme.hearthDark(),
    }.entries) {
      testWidgets('${entry.key}: the faded title keeps 4.5:1 contrast',
          (tester) async {
        await pump(tester, row(const WorkRowFacts(played: true)),
            theme: entry.value);
        expect(find.byKey(const Key('played-7')), findsOneWidget);
        final title = tester.widget<Text>(find.text('Aurora season'));
        final fg = title.style!.color!;
        final bg = entry.value.colorScheme.surface;
        expect(fg, isNot(entry.value.colorScheme.onSurface),
            reason: 'it has to look different from an unplayed row');
        expect(_contrast(fg, bg), greaterThanOrEqualTo(4.5));
      });
    }

    testWidgets('screen readers hear that it was played', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, row(const WorkRowFacts(played: true, audio: true)));
      expect(find.bySemanticsLabel(RegExp('Played')), findsWidgets);
      handle.dispose();
    });

    testWidgets('a finished text is announced as finished, not played',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, row(const WorkRowFacts(played: true)));
      expect(find.bySemanticsLabel(RegExp('Finished')), findsWidgets);
      expect(find.bySemanticsLabel(RegExp('Played')), findsNothing);
      handle.dispose();
    });
  });

  testWidgets('at 320dp and 2x text the length still shows in full',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await pump(tester, row(const WorkRowFacts(durationMs: 50 * 60000)));
    final meta = tester.renderObject<RenderParagraph>(
        find.text('Night Sky · 5 Aug · 50\u00A0min'));
    expect(meta.didExceedMaxLines, isFalse);
  });

  testWidgets('at 320dp and 1.3x text the row keeps its picture',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await pump(tester, row(const WorkRowFacts(durationMs: 50 * 60000)));
    expect(find.byKey(const Key('glyph-7')), findsOneWidget);
    final meta = tester.renderObject<RenderParagraph>(
        find.text('Night Sky · 5 Aug · 50\u00A0min'));
    expect(meta.didExceedMaxLines, isFalse);
  });

  for (final curve in {
    'linear': const TextScaler.linear(2.0),
    'android14-nonlinear': const _NonLinearTextScaler(2.0),
  }.entries) {
    testWidgets('a busy row survives 320dp at 2x (${curve.key})',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: OhTheme.light(),
        home: MediaQuery(
          data: MediaQueryData(
              size: const Size(320, 640), textScaler: curve.value),
          child: Scaffold(
            body: ListView(children: [
              row(
                const WorkRowFacts(
                    isNew: true,
                    downloaded: true,
                    queued: true,
                    transcribed: true,
                    video: true,
                    durationMs: 95 * 60000,
                    progressMs: 30 * 60000),
                show: 'The Extraordinarily Comprehensive Night Sky Podcast',
                title: 'A Rather Longer Episode Title Than Any Row Would Like',
              ),
            ]),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  group('text works and audiobooks share the anatomy', () {
    final firstSeen = DateTime.utc(2026, 8, 5)
            .difference(DateTime.utc(1970))
            .inDays;
    Work textWork(
            {String kind = 'article',
            String? sourceUrl = 'https://www.essays.example/on-tides',
            String persistence = 'work',
            bool pinned = false}) =>
        Work(
            id: 9,
            profileId: 1,
            kind: kind,
            title: 'On tides',
            sourceUrl: sourceUrl,
            persistence: persistence,
            firstSeenEpochDay: firstSeen,
            pinned: pinned,
            showTranslationLayer: false);

    Widget textRow(Work w, WorkRowFacts facts,
            {VoidCallback? onRead, Widget? trailing}) =>
        WorkRow(
          work: w,
          facts: facts,
          onRead: onRead ?? () {},
          trailing: trailing,
          menuBuilder: (_) => const [
            PopupMenuItem(value: 'x', child: Text('Something')),
          ],
          onMenu: (_) {},
        );

    testWidgets('an article says its site, its day and its reading time',
        (tester) async {
      await pump(tester,
          textRow(textWork(), const WorkRowFacts(readingMs: 3 * 60000)));
      expect(find.text('essays.example · 5 Aug · 3\u00A0min\u00A0read'), findsOneWidget);
    });

    testWidgets('a book with no address says what it is', (tester) async {
      await pump(
          tester,
          textRow(textWork(kind: 'book', sourceUrl: null),
              const WorkRowFacts(readingMs: 95 * 60000)));
      expect(find.text('Book · 5 Aug · 1\u00A0hr\u00A035\u00A0min\u00A0read'), findsOneWidget);
    });

    testWidgets('a text work has a glyph where art would be, and Read, '
        'never Play', (tester) async {
      await pump(tester, textRow(textWork(), const WorkRowFacts()));
      expect(find.byKey(const Key('glyph-9')), findsOneWidget);
      expect(find.byKey(const Key('read-9')), findsOneWidget);
      expect(find.byKey(const Key('play-9')), findsNothing);
    });

    testWidgets('a text work part-read shows the bar and the time left',
        (tester) async {
      await pump(
          tester,
          textRow(textWork(),
              const WorkRowFacts(readingMs: 10 * 60000, partFraction: 0.25)));
      final bar = tester
          .widget<LinearProgressIndicator>(find.byKey(const Key('progress-9')));
      expect(bar.value, 0.25);
      expect(find.text('essays.example · 5 Aug · 8\u00A0min\u00A0left'), findsOneWidget);
    });

    testWidgets('pinned is a marker, a word like the others', (tester) async {
      await pump(tester,
          textRow(textWork(pinned: true), const WorkRowFacts(pinned: true)));
      expect(find.text('Pinned'), findsOneWidget);
    });

    testWidgets('the trailing slot ends the action line, after the menu, '
        'so it takes no width from the title', (tester) async {
      await pump(
          tester,
          textRow(textWork(), const WorkRowFacts(),
              trailing: const Icon(Icons.drag_handle, key: Key('handle'))));
      final handle = tester.getCenter(find.byKey(const Key('handle')));
      final menu = tester.getCenter(find.byKey(const Key('menu-9')));
      expect(handle.dx, greaterThan(menu.dx));
      expect(handle.dy, closeTo(menu.dy, 1));
      final title = tester.getTopRight(find.text('On tides'));
      expect(handle.dy, greaterThan(title.dy),
          reason: 'below the title, not beside it');
    });

    testWidgets('an audio episode with no transcript offers no Read',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: WorkRow(
        work: work(),
        episode: episode(),
        facts: const WorkRowFacts(audio: true),
        onPlay: () {},
        onRead: () {},
        menuBuilder: (_) => const [],
        onMenu: (_) {},
      ))));
      expect(find.byKey(const Key('read-7')), findsNothing);
      expect(find.byKey(const Key('play-7')), findsOneWidget);
    });

    testWidgets('a transcribed audio episode offers Read beside Play',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: WorkRow(
        work: work(),
        episode: episode(),
        facts: const WorkRowFacts(audio: true, transcribed: true),
        onPlay: () {},
        onRead: () {},
        menuBuilder: (_) => const [],
        onMenu: (_) {},
      ))));
      expect(find.byTooltip('Read transcript'), findsOneWidget);
      expect(find.byKey(const Key('play-7')), findsOneWidget);
    });

    test('of() reads a text work’s size and place from the list state', () {
      final state = WorkListState(
        textSizes: {9: (segments: 8, chars: 13500)},
        readIdx: {9: 2},
      );
      final f = WorkRowFacts.of(textWork(), null, state);
      expect(f.audio, isFalse);
      expect(f.readable, isTrue);
      expect(f.readingMs, 10 * 60000);
      expect(f.partFraction, 0.25);
      expect(f.inProgress, isTrue);
      expect(f.isNew, isFalse, reason: 'only a feed item is ever new');
    });

    test('of() calls a finished work played', () {
      final w = Work(
          id: 9,
          profileId: 1,
          kind: 'book',
          title: 'Done',
          persistence: 'work',
          firstSeenEpochDay: 1,
          pinned: false,
          finishedEpochDay: 5,
          showTranslationLayer: false);
      expect(WorkRowFacts.of(w, null, WorkListState.empty).played, isTrue);
    });

    test('of() reads an audiobook’s place as files reached of its files',
        () {
      final book = textWork(kind: 'audiobook', sourceUrl: null);
      final f = WorkRowFacts.of(book, null,
          const WorkListState(fileIdx: {9: 1}, fileCounts: {9: 4}));
      expect(f.audio, isTrue);
      expect(f.readable, isFalse);
      expect(f.partFraction, 0.25);
    });

    test('Kept is a feed item someone kept, not every library work', () {
      final kept = Work(
          id: 7,
          profileId: 1,
          kind: 'episode',
          title: 'x',
          persistence: 'work',
          firstSeenEpochDay: 1,
          pinned: false,
          showTranslationLayer: false);
      expect(
          WorkRowFacts.of(kept, episode(), WorkListState.empty).kept, isTrue);
      expect(WorkRowFacts.of(work(), episode(), WorkListState.empty).kept,
          isFalse);
      expect(
          WorkRowFacts.of(textWork(), null, WorkListState.empty).kept, isFalse);
    });
  });

  group('the compact last line', () {
    Future<void> at(WidgetTester tester, double width, Widget child,
        {double scale = 1.0}) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      await pump(tester, child);
    }

    testWidgets('markers share the line with the actions when they fit',
        (tester) async {
      await at(tester, 412,
          row(const WorkRowFacts(isNew: true, audio: true, durationMs: 1)));
      final marker = tester.getCenter(find.text('New'));
      final play = tester.getCenter(find.byKey(const Key('play-7')));
      expect((marker.dy - play.dy).abs(), lessThan(2));
      expect(marker.dx, lessThan(play.dx), reason: 'markers left, actions right');
    });

    testWidgets('markers that don’t fit take a line above the actions, '
        'never the title’s width', (tester) async {
      await at(
          tester,
          320,
          WorkRow(
            work: work(),
            episode: episode(),
            facts: const WorkRowFacts(
                isNew: true,
                downloaded: true,
                transcribed: true,
                kept: true,
                audio: true),
            showTitle: 'Night Sky',
            onPlay: () {},
            onRead: () {},
            menuBuilder: (_) => const [],
            onMenu: (_) {},
            trailing: const SizedBox(width: 48, height: 48),
          ),
          scale: 1.3);
      expect(tester.takeException(), isNull);
      final marker = tester.getBottomLeft(find.text('Kept'));
      final play = tester.getTopLeft(find.byKey(const Key('play-7')));
      expect(marker.dy, lessThanOrEqualTo(play.dy + 1));
    });

    testWidgets('a two-line row at 360 dp is under 130 dp tall, so four '
        'or more fit on a phone screen', (tester) async {
      await at(
          tester,
          360,
          row(
              const WorkRowFacts(
                  isNew: true, kept: true, audio: true, durationMs: 1),
              title: 'Aurora season, and what the solar maximum means for '
                  'the north'));
      final h = tester.getSize(find.byType(ListTile)).height;
      expect(h, lessThanOrEqualTo(130));
    });
  });
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// Android 14 scales large text more slowly than small text; a layout must
/// not assume proportional growth (see the ergonomic-ux sweep template).
class _NonLinearTextScaler extends TextScaler {
  const _NonLinearTextScaler(this.factor);
  final double factor;

  @override
  double scale(double fontSize) {
    final taper = (fontSize / 30.0).clamp(0.0, 1.0);
    return fontSize * (factor - (factor - 1.0) * 0.3 * taper);
  }

  @override
  double get textScaleFactor => factor;

  @override
  bool operator ==(Object other) =>
      other is _NonLinearTextScaler && other.factor == factor;

  @override
  int get hashCode => factor.hashCode;
}
