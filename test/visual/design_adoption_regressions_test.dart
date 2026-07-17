import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
