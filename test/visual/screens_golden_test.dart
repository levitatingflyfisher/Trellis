import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/core/providers.dart';
import 'package:trellis/core/theme.dart';
import 'package:trellis/features/curriculum/data/curriculum_parser.dart';
import 'package:trellis/features/curriculum/domain/models.dart';
import 'package:trellis/features/curriculum/presentation/course_map_screen.dart';
import 'package:trellis/features/curriculum/presentation/library_screen.dart';
import 'package:trellis/features/study/presentation/study_session_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Renders the real screens to golden PNGs for layout inspection.
/// Run: flutter test --update-goldens test/visual/screens_golden_test.dart
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
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs), ...extra],
        child: MaterialApp(theme: trellisTheme(Brightness.light), home: screen),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('library', (t) async {
    // Override the async course list so the shot shows the populated library
    // (the real loader is covered by the boot test in widget_test.dart).
    await pumpScreen(t, const LibraryScreen(),
        extra: [coursesProvider.overrideWith((ref) async => [course])]);
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/library.png'));
  });

  testWidgets('course map', (t) async {
    await pumpScreen(t, CourseMapScreen(course: course));
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/course_map.png'));
  });

  testWidgets('study — intake', (t) async {
    await pumpScreen(t, StudySessionScreen(course: course));
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/study_intake.png'));
  });

  testWidgets('study — recall item', (t) async {
    await pumpScreen(t, StudySessionScreen(course: course));
    await t.ensureVisible(find.text('Recall'));
    await t.pumpAndSettle();
    await t.tap(find.text('Recall'));
    await t.pumpAndSettle();
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/study_item.png'));
  });
}
