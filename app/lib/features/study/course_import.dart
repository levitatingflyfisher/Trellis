import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../db/database.dart';

/// The bundled Trellis starter course. Registered as an importable sample
/// only — nothing here runs at boot; every import below sits behind the
/// user's tap (ADR-0003: the user's hand does the importing).
const String starterCourseAsset = 'assets/courses/kalman.ohcourse';

/// Validates [raw] with study_core's strict parser and stores it (the parser
/// law: a file that doesn't parse leaves zero rows). Returns the course row
/// id; throws [FormatException] with a path-qualified message otherwise.
Future<int> importCourseText(
        {required AppDatabase db, required int profileId, required String raw}) =>
    db.studyDao.importCourse(
        profileId: profileId,
        raw: raw,
        nowMs: DateTime.now().millisecondsSinceEpoch);

/// Imports the bundled starter course — called from a button, never boot.
Future<int> importStarterCourse(
        {required AppDatabase db, required int profileId}) async =>
    importCourseText(
        db: db,
        profileId: profileId,
        raw: await rootBundle.loadString(starterCourseAsset));

/// The thin file_picker wrapper: pick one `.ohcourse` (or `.json`) file and
/// delegate to [importCourseText]. Returns null when the picker is
/// dismissed; propagates the parser's [FormatException] for a calm surface.
Future<int?> pickAndImportCourse(
    {required AppDatabase db, required int profileId}) async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['ohcourse', 'json'],
    withData: true,
  );
  final file = result?.files.firstOrNull;
  if (file == null) return null;
  final bytes = file.bytes ?? await File(file.path!).readAsBytes();
  return importCourseText(
      db: db, profileId: profileId, raw: utf8.decode(bytes));
}

/// Paste-a-course dialog (the donor flow kept — fixes the Trellis jank of
/// paste being the ONLY road in, without dropping it). The strict parser's
/// error is shown inline, calmly; the dialog never half-imports. Returns the
/// imported course row id, or null on cancel.
Future<int?> showCoursePasteDialog(BuildContext context,
    {required AppDatabase db, required int profileId}) {
  return showDialog<int>(
    context: context,
    builder: (ctx) => _PasteCourseDialog(db: db, profileId: profileId),
  );
}

class _PasteCourseDialog extends StatefulWidget {
  final AppDatabase db;
  final int profileId;
  const _PasteCourseDialog({required this.db, required this.profileId});

  @override
  State<_PasteCourseDialog> createState() => _PasteCourseDialogState();
}

class _PasteCourseDialogState extends State<_PasteCourseDialog> {
  // Owned by the State so it outlives the route's exit animation — disposing
  // it the moment showDialog returned crashed the still-animating TextField.
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    try {
      final id = await importCourseText(
          db: widget.db, profileId: widget.profileId, raw: _controller.text);
      if (!mounted) return;
      Navigator.pop(context, id);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Paste a course'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('A .ohcourse file is JSON — paste its text here.'),
            const SizedBox(height: 8),
            TextField(
              key: const Key('course-json'),
              controller: _controller,
              minLines: 6,
              maxLines: 12,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '{ "schemaVersion": "1.0", … }',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Cancel')),
        FilledButton(onPressed: _import, child: const Text('Import')),
      ],
    );
  }
}
