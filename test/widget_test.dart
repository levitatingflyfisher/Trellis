import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/core/providers.dart';
import 'package:trellis/core/theme.dart';
import 'package:trellis/features/curriculum/data/course_repository.dart';
import 'package:trellis/features/curriculum/domain/models.dart';
import 'package:trellis/features/curriculum/presentation/library_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Real load path: the bundled course is discovered + parsed via the repo.
  // (An async test() drives real rootBundle I/O, which pump()/pumpAndSettle do
  // not do inside a widget's FutureProvider.)
  test('the bundled tracking course is discoverable via listCourses', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final courses = await CourseRepository(prefs).listCourses();
    expect(courses.map((c) => c.id), contains('multi-target-tracking'));
    final course = courses.firstWhere((c) => c.id == 'multi-target-tracking');
    expect(course.nodes.length, greaterThan(20));
  });

  // Render path: the library shows a course card (provider overridden so the
  // test is deterministic and doesn't hang on the async loading spinner).
  testWidgets('library renders a course card', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final course = const Course(
      id: 'x',
      title: 'Test Course',
      nodes: [
        KnowledgeNode(
          id: 'n',
          title: 'N',
          intake: 'i',
          items: [QaItem(id: 'q', rung: 1, prompt: 'p', answer: 'a')],
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          coursesProvider.overrideWith((ref) async => [course]),
        ],
        child: MaterialApp(
          theme: TrellisTheme(Brightness.light),
          home: const LibraryScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Test Course'), findsOneWidget);
  });
}
