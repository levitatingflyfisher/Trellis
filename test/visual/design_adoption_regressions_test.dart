import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trellis/core/markdown.dart';
import 'package:trellis/core/providers.dart';
import 'package:trellis/core/theme.dart';
import 'package:trellis/features/curriculum/data/curriculum_parser.dart';
import 'package:trellis/features/curriculum/domain/models.dart';
import 'package:trellis/features/curriculum/presentation/course_map_screen.dart';
import 'package:trellis/features/curriculum/presentation/library_screen.dart';
import 'package:trellis/features/study/presentation/study_session_screen.dart';

/// Pins the visual-hierarchy truths the openhearth_design adoption exposed.
///
/// OhTheme's role ladder maps `titleMedium` to a 14px label — smaller than
/// its 16px `bodyMedium` — so any screen using `titleMedium` as a heading
/// over body text silently inverts its hierarchy. And OhTheme's global
/// `iconTheme` (primary-colored icons) is treated by M3 `IconButton` as an
/// override, which paints a `IconButton.filled` glyph primary-on-primary —
/// invisible. These tests state the invariants directly so a future theme
/// change fails loudly instead of only shifting golden pixels.
void main() {
  late SharedPreferences prefs;
  late Course course;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    course = parseCourseString(await rootBundle
        .loadString('assets/courses/multi-target-tracking.ohcourse.json'));
  });

  Future<void> pumpScreen(WidgetTester tester, Widget screen,
      {List<Override> extra = const []}) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          ...extra
        ],
        child: MaterialApp(theme: TrellisTheme(Brightness.light), home: screen),
      ),
    );
    await tester.pumpAndSettle();
  }

  double fontSizeOf(WidgetTester tester, Finder finder) => tester
      .renderObject<RenderParagraph>(finder)
      .text
      .style!
      .fontSize!;

  testWidgets('library card title outranks its subtitle', (t) async {
    await pumpScreen(t, const LibraryScreen(),
        extra: [coursesProvider.overrideWith((ref) async => [course])]);
    final titleSize = fontSizeOf(t, find.text(course.title));
    final subtitleSize = fontSizeOf(t, find.text(course.subtitle));
    expect(titleSize, greaterThan(subtitleSize),
        reason: 'the course title must read as the heading of its card');
  });

  testWidgets('library empty-state heading outranks its explainer', (t) async {
    await pumpScreen(t, const LibraryScreen(),
        extra: [coursesProvider.overrideWith((ref) async => [])]);
    final headingSize = fontSizeOf(t, find.text('No courses yet'));
    final bodySize =
        fontSizeOf(t, find.textContaining('trellis-author'));
    expect(headingSize, greaterThan(bodySize));
  });

  testWidgets('course-map "Concepts" heading outranks the body text',
      (t) async {
    await pumpScreen(t, CourseMapScreen(course: course));
    final headingSize = fontSizeOf(t, find.text('Concepts'));
    final bodySize = fontSizeOf(t, find.text(course.description));
    expect(headingSize, greaterThan(bodySize));
  });

  // Effective font size of the MdText matched by [pred]: its explicit style,
  // or the bodyMedium default MdText falls back to — exactly what renders.
  double mdSizeOf(WidgetTester t, bool Function(MdText) pred) {
    final finder =
        find.byWidgetPredicate((w) => w is MdText && pred(w));
    final element = t.element(finder);
    final md = element.widget as MdText;
    final style = md.style ?? Theme.of(element).textTheme.bodyMedium!;
    return style.fontSize!;
  }

  Course singleItemCourse(RetrievalItem item) => Course(
        id: 'design-regression',
        title: 'Design regression',
        nodes: [
          KnowledgeNode(
            id: 'n1',
            title: 'Node',
            intake: 'Some intake prose.',
            items: [item],
          ),
        ],
      );

  Future<void> pumpToItem(WidgetTester t, RetrievalItem item) async {
    await pumpScreen(t, StudySessionScreen(course: singleItemCourse(item)));
    await t.tap(find.text('Recall'));
    await t.pumpAndSettle();
  }

  double bodySize() =>
      TrellisTheme(Brightness.light).textTheme.bodyMedium!.fontSize!;

  testWidgets('cloze prompt outranks the body text under it', (t) async {
    await pumpToItem(
        t,
        const ClozeItem(
          id: 'c1',
          rung: 1,
          text: 'The capital of France is {{c1::Paris}}.',
          answers: {'c1': 'Paris'},
        ));
    final promptSize = mdSizeOf(t, (w) => w.data.contains('____'));
    expect(promptSize, greaterThan(bodySize()),
        reason: 'the cloze passage is the card\'s heading — it must outrank '
            'the 16px body/answer text beneath it');
  });

  testWidgets('free-recall prompt outranks the body text under it', (t) async {
    await pumpToItem(
        t,
        const QaItem(
          id: 'q1',
          rung: 1,
          prompt: 'What is the capital of France?',
          answer: 'Paris',
        ));
    final promptSize =
        mdSizeOf(t, (w) => w.data == 'What is the capital of France?');
    expect(promptSize, greaterThan(bodySize()),
        reason: 'the QA/procedure prompt is the card\'s heading — it must '
            'outrank the 16px answer text revealed beneath it');
  });

  testWidgets('discrimination prompt outranks its choices', (t) async {
    await pumpToItem(
        t,
        const DiscriminationItem(
          id: 'd1',
          rung: 1,
          prompt: 'Which city is the capital of France?',
          choices: ['Paris', 'Lyon'],
          correctIndex: 0,
        ));
    final promptSize =
        mdSizeOf(t, (w) => w.data == 'Which city is the capital of France?');
    final choiceSize = mdSizeOf(t, (w) => w.data == 'Paris');
    expect(promptSize, greaterThan(choiceSize),
        reason: 'the question must read as the heading over its 16px choices');
  });

  testWidgets('RSVP play glyph is visible on its filled button', (t) async {
    await pumpScreen(t, StudySessionScreen(course: course));
    final theme = TrellisTheme(Brightness.light);
    final glyphColor = t
        .renderObject<RenderParagraph>(find.descendant(
            of: find.byIcon(Icons.play_arrow),
            matching: find.byType(RichText)))
        .text
        .style!
        .color;
    expect(glyphColor, isNot(theme.colorScheme.primary),
        reason: 'IconButton.filled paints a primary background — a '
            'primary-colored glyph disappears into it');
    expect(glyphColor, theme.colorScheme.onPrimary);
  });
}
