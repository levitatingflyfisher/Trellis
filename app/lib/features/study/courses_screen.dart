import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:study_core/study_core.dart' as study;

import '../../db/database.dart';
import '../brain/brain_settings_screen.dart';
import '../brain/brain_store.dart';
import 'course_import.dart';
import 'course_map_screen.dart';

typedef _Entry = ({CourseRow row, study.Course course});

/// The Courses tab: this reader's imported courses. Every entry parsed here
/// was validated by the strict parser at import time; the bundled starter
/// course is offered as a sample, never auto-imported.
class CoursesScreen extends StatefulWidget {
  final AppDatabase db;
  final Profile profile;

  /// Opens Backup & migrate; the shell wires it (the LibraryScreen
  /// `onOpenModels` pattern — the tab offers the door, the shell owns the
  /// navigation).
  final VoidCallback? onOpenBackup;

  /// The Thinking door's store. Tests inject in-memory secrets; the app
  /// default is the production wiring (secure storage + real Anthropic).
  final BrainStore? brainStore;

  /// Gates the local-model tier row on the Thinking screen. Defaults to
  /// "not the web" — the same truth bootstrap_web encodes in
  /// DeviceServices.localMlAvailable, which this tab cannot reach (the
  /// shell passes the shell's services nowhere near here).
  final bool? localMlAvailable;
  const CoursesScreen(
      {super.key,
      required this.db,
      required this.profile,
      this.onOpenBackup,
      this.brainStore,
      this.localMlAvailable});

  @override
  State<CoursesScreen> createState() => _CoursesScreenState();
}

class _CoursesScreenState extends State<CoursesScreen> {
  List<_Entry>? _entries;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await widget.db.studyDao.coursesOf(widget.profile.id);
    final entries = <_Entry>[];
    for (final row in rows) {
      try {
        entries.add((row: row, course: study.parseCourseString(row.raw)));
      } on FormatException {
        // Import validated this text; a row that no longer parses is filtered
        // rather than crashing the whole tab.
      }
    }
    if (!mounted) return;
    setState(() => _entries = entries);
  }

  Future<void> _paste() async {
    final id = await showCoursePasteDialog(context,
        db: widget.db, profileId: widget.profile.id);
    if (id != null) await _load();
  }

  Future<void> _pickFile() async {
    try {
      final id = await pickAndImportCourse(
          db: widget.db, profileId: widget.profile.id);
      if (id != null) await _load();
    } on FormatException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text("That file couldn't be read as a course. ${e.message}")));
    }
  }

  Future<void> _addStarter() async {
    await importStarterCourse(db: widget.db, profileId: widget.profile.id);
    await _load();
  }

  void _addSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.content_paste),
              title: const Text('Paste a course'),
              onTap: () {
                Navigator.pop(sheet);
                _paste();
              },
            ),
            ListTile(
              leading: const Icon(Icons.file_open_outlined),
              title: const Text('Import a course file'),
              onTap: () {
                Navigator.pop(sheet);
                _pickFile();
              },
            ),
            ListTile(
              leading: const Icon(Icons.spa_outlined),
              title: const Text('Add the starter course'),
              onTap: () {
                Navigator.pop(sheet);
                _addStarter();
              },
            ),
          ],
        ),
      ),
    );
  }

  /// The Thinking door (proposal-2 §7): brain tier + BYOK key settings.
  void _openThinking() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => BrainSettingsScreen(
        store: widget.brainStore ?? BrainStore.production(),
        localMlAvailable: widget.localMlAvailable ?? !kIsWeb,
      ),
    ));
  }

  Future<void> _open(_Entry e) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => CourseMapScreen(
          db: widget.db, courseRow: e.row, course: e.course),
    ));
    await _load(); // mastery may have moved while we were away
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Courses'),
        actions: [
          IconButton(
            key: const Key('open-thinking'),
            tooltip: 'Thinking',
            icon: const Icon(Icons.psychology_outlined),
            onPressed: _openThinking,
          ),
          if (widget.onOpenBackup != null)
            IconButton(
              key: const Key('open-backup'),
              tooltip: 'Backup & migrate',
              icon: const Icon(Icons.settings_backup_restore),
              onPressed: widget.onOpenBackup,
            ),
        ],
      ),
      floatingActionButton: (entries == null || entries.isEmpty)
          ? null
          : FloatingActionButton.extended(
              onPressed: _addSheet,
              icon: const Icon(Icons.add),
              label: const Text('Add')),
      body: switch (entries) {
        null => const Center(child: CircularProgressIndicator()),
        [] => _EmptyState(
            onPaste: _paste, onPick: _pickFile, onStarter: _addStarter),
        _ => ListView.builder(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: entries.length,
            itemBuilder: (_, i) => _courseTile(entries[i]),
          ),
      },
    );
  }

  Widget _courseTile(_Entry e) {
    final n = e.course.nodes.length;
    final meta = [
      if (e.course.subject.isNotEmpty) e.course.subject,
      if (e.course.level.isNotEmpty) e.course.level,
      '$n concept${n == 1 ? '' : 's'}',
    ].join('  ·  ');
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: () => _open(e),
        title: Text(e.course.title,
            overflow: TextOverflow.ellipsis, maxLines: 2),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (e.course.subtitle.isNotEmpty)
              Text(e.course.subtitle,
                  overflow: TextOverflow.ellipsis, maxLines: 2),
            Text(meta, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onPaste;
  final VoidCallback onPick;
  final VoidCallback onStarter;
  const _EmptyState(
      {required this.onPaste, required this.onPick, required this.onStarter});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.school_outlined,
                  size: 56, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text('Nothing to study yet.',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(
                  'A course is a ladder of concepts, drilled until they '
                  'stay. Bring a .ohcourse file, or begin with the starter.',
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton.icon(
                  onPressed: onPaste,
                  icon: const Icon(Icons.content_paste),
                  label: const Text('Paste a course')),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                  onPressed: onPick,
                  icon: const Icon(Icons.file_open_outlined),
                  label: const Text('Import a course file')),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                  onPressed: onStarter,
                  icon: const Icon(Icons.spa_outlined),
                  label: const Text('Add the starter course')),
            ],
          ),
        ),
      ),
    );
  }
}
