import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openhearth_design/openhearth_design.dart';
import 'package:trellis/db/database.dart';
import 'package:trellis/features/episodes/episode_row.dart';

/// ADR-0016 section 1: a row that says what state the episode is in.
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

  Widget row(EpisodeRowFacts facts,
          {String? show = 'Night Sky', String title = 'Aurora season'}) =>
      EpisodeRow(
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

  group('EpisodeRowFacts', () {
    test('a position short of the end, not played, is in progress', () {
      const f = EpisodeRowFacts(durationMs: 600000, progressMs: 150000);
      expect(f.inProgress, isTrue);
      expect(f.fraction, 0.25);
      expect(f.leftMs, 450000);
    });

    test('a played episode is never in progress, wherever it stopped', () {
      const f = EpisodeRowFacts(
          durationMs: 600000, progressMs: 150000, played: true);
      expect(f.inProgress, isFalse);
    });

    test('no position, or none past the start, is not in progress', () {
      expect(const EpisodeRowFacts(durationMs: 600000).inProgress, isFalse);
      expect(
          const EpisodeRowFacts(durationMs: 600000, progressMs: 0).inProgress,
          isFalse);
    });

    test('a position with no known length is in progress without a bar',
        () {
      const f = EpisodeRowFacts(progressMs: 150000);
      expect(f.inProgress, isTrue);
      expect(f.fraction, isNull);
      expect(f.leftMs, isNull);
    });

    test('of() reads the list state for this episode', () {
      final state = EpisodeListState(
          queued: {7}, progressMs: {7: 1000}, transcribed: {7});
      final f = EpisodeRowFacts.of(
          episode(durationMs: 600000, finishedAtMs: 5),
          state,
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
    await pump(tester, row(const EpisodeRowFacts(durationMs: 45 * 60000)));
    expect(find.text('Night Sky · 5 Aug · 45 min'), findsOneWidget);
  });

  testWidgets('on the podcast page the show name is left out',
      (tester) async {
    await pump(tester,
        row(const EpisodeRowFacts(durationMs: 45 * 60000), show: null));
    expect(find.text('5 Aug · 45 min'), findsOneWidget);
  });

  testWidgets('an episode in progress shows a thin bar and the time left',
      (tester) async {
    await pump(
        tester,
        row(const EpisodeRowFacts(
            durationMs: 45 * 60000, progressMs: 22 * 60000)));
    expect(find.text('Night Sky · 5 Aug · 23 min left'), findsOneWidget);
    final bar = tester
        .widget<LinearProgressIndicator>(find.byKey(const Key('progress-7')));
    expect(bar.value, closeTo(22 / 45, 0.001));
  });

  testWidgets('an unplayed, untouched episode has no bar', (tester) async {
    await pump(tester, row(const EpisodeRowFacts(durationMs: 45 * 60000)));
    expect(find.byKey(const Key('progress-7')), findsNothing);
    expect(find.byKey(const Key('played-7')), findsNothing);
  });

  testWidgets('markers are words, not just colours', (tester) async {
    await pump(
        tester,
        row(const EpisodeRowFacts(
            isNew: true,
            downloaded: true,
            queued: true,
            transcribed: true,
            video: true)));
    for (final label in [
      'New',
      'Downloaded',
      'In Queue',
      'Transcript',
      'Video'
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.byKey(const Key('unread-dot-7')), findsOneWidget);
    expect(find.byKey(const Key('downloaded-7')), findsOneWidget);
  });

  testWidgets('a row with nothing to say carries no markers',
      (tester) async {
    await pump(tester, row(const EpisodeRowFacts()));
    for (final label in [
      'New',
      'Downloaded',
      'In Queue',
      'Transcript',
      'Video'
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
        await pump(tester, row(const EpisodeRowFacts(played: true)),
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
      await pump(tester, row(const EpisodeRowFacts(played: true)));
      expect(find.bySemanticsLabel(RegExp('Played')), findsWidgets);
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
    await pump(tester, row(const EpisodeRowFacts(durationMs: 50 * 60000)));
    final meta = tester.renderObject<RenderParagraph>(
        find.text('Night Sky · 5 Aug · 50 min'));
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
                const EpisodeRowFacts(
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
