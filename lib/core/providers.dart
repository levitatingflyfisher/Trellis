import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/curriculum/data/course_repository.dart';
import '../features/curriculum/domain/models.dart';
import '../features/study/data/card_repository.dart';

/// Overridden in main() with the resolved instance.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('override sharedPreferencesProvider in main()'),
);

final courseRepositoryProvider = Provider<CourseRepository>(
  (ref) => CourseRepository(ref.watch(sharedPreferencesProvider)),
);

final cardRepositoryProvider = Provider<CardRepository>(
  (ref) => CardRepository(ref.watch(sharedPreferencesProvider)),
);

final coursesProvider = FutureProvider<List<Course>>(
  (ref) => ref.watch(courseRepositoryProvider).listCourses(),
);
