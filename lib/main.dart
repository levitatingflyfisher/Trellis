import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/providers.dart';
import 'core/theme.dart';
import 'features/curriculum/presentation/library_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: const TrellisApp(),
    ),
  );
}

class TrellisApp extends StatelessWidget {
  const TrellisApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Trellis',
      debugShowCheckedModeBanner: false,
      theme: TrellisTheme(Brightness.light),
      darkTheme: TrellisTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const LibraryScreen(),
    );
  }
}
