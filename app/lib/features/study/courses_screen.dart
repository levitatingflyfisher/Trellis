import 'dart:async';

import 'package:flutter/material.dart';
import 'package:study_core/study_core.dart' as study;

import '../../db/database.dart';
import '../intake/paste_intake.dart' show epochDayUtcNow;
import 'card_editor_screen.dart';
import 'card_images.dart' show CardPictures;
import 'card_store.dart';
import 'course_import.dart';
import 'course_map_screen.dart';
import 'daily_review_screen.dart';
import '../shared/capped_body.dart';

typedef _Entry = ({CourseRow row, study.Course course});

/// The Courses tab: this reader's imported courses. Every entry parsed here
/// was validated by the strict parser at import time; the bundled example
/// course is offered as an example, never auto-imported, and marked as one
/// once it is here.
class CoursesScreen extends StatefulWidget {
  final AppDatabase db;
  final Profile profile;

  const CoursesScreen(
      {super.key,
      required this.db,
      required this.profile});

  @override
  State<CoursesScreen> createState() => _CoursesScreenState();
}

class _CoursesScreenState extends State<CoursesScreen> {
  List<_Entry>? _entries;

  /// The study crown's home surface (Phase 1): daily review's OWN due
  /// count, separate from any course's — null while loading, 0 hides the
  /// chip entirely (quiet means quiet, ADR-0003 law 5: no permanent zero).
  int? _dailyReviewDue;

  /// The profile's scheduler choice ('fsrs' the default, or 'classic') —
  /// the study crown's toggle. Loaded once per [_load]; grading itself
  /// reads it fresh from the database (study_session_screen.dart), so this
  /// field only drives the settings menu's own checkmark.
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
    final due = await widget.db.dailyReviewDao
        .dueCount(widget.profile.id, epochDayUtcNow());
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _dailyReviewDue = due;
    });
  }

  Future<void> _openDailyReview() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) =>
            DailyReviewScreen(db: widget.db, profileId: widget.profile.id)));
    await _load(); // the due count moved
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
      // The strict parser's message names JSON keys; it goes to the log.
      debugPrint('Course file refused: ${e.message}');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("That file isn’t a course Trellis can read. "
              'Paste its text instead to see why.')));
    }
  }

  /// A card made from no course goes into My cards, made with it.
  Future<void> _makeCard() async {
    final saved = await showCardEditor(context,
        title: 'Make a card',
        pictures: CardPictures(widget.db),
        onSave: (draft, _) =>
            addToMyCards(widget.db, widget.profile.id, draft));
    if (saved) await _load();
  }

  Future<void> _addExample() async {
    await importExampleCourse(db: widget.db, profileId: widget.profile.id);
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
              leading: const Icon(Icons.style_outlined),
              title: const Text('Make a card'),
              subtitle: const Text('It goes in My cards'),
              onTap: () {
                Navigator.pop(sheet);
                _makeCard();
              },
            ),
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
            if (!(_entries ?? const <_Entry>[])
                .any((e) => e.row.courseId == exampleCourseId))
              ListTile(
                leading: const Icon(Icons.spa_outlined),
                title: const Text('Try an example course'),
                subtitle: const Text('A short course on Kalman filters'),
                onTap: () {
                  Navigator.pop(sheet);
                  _addExample();
                },
              ),
          ],
        ),
      ),
    );
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
        // No ⋮: Thinking, What you’ve built and FSRS are app-wide and
        // live in Settings (board-0131).
      ),
      floatingActionButton: (entries == null || entries.isEmpty)
          ? null
          : FloatingActionButton.extended(
              onPressed: _addSheet,
              icon: const Icon(Icons.add),
              label: const Text('Add')),
      body: CappedBody(child: Column(
        children: [
          if ((_dailyReviewDue ?? 0) > 0) _dailyReviewChip(),
          Expanded(
            child: switch (entries) {
              null => const Center(child: CircularProgressIndicator()),
              [] => _EmptyState(
                  onPaste: _paste,
                  onPick: _pickFile,
                  onExample: _addExample,
                  onMakeCard: _makeCard),
              _ => ListView.builder(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: entries.length,
                  itemBuilder: (_, i) => _courseTile(entries[i]),
                ),
            },
          ),
        ],
      )),
    );
  }

  /// The quiet due chip: only rendered at all when there is something due
  /// (see [_dailyReviewDue]'s doc comment) — never a permanent zero.
  Widget _dailyReviewChip() => Card(
        key: const Key('daily-review-chip'),
        margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          onTap: _openDailyReview,
          // Campaign 9 Phase 1: distinct from the Echo door's
          // auto_awesome_outlined — the two shared a glyph and neither
          // meaning was legible for it.
          leading: const Icon(Icons.today_outlined),
          title: const Text('Daily review'),
          subtitle: Text('$_dailyReviewDue due'),
          trailing: const Icon(Icons.chevron_right),
        ),
      );

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
            if (e.row.courseId == exampleCourseId)
              Text('Example course',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.primary)),
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
  final VoidCallback onExample;
  final VoidCallback onMakeCard;
  const _EmptyState(
      {required this.onPaste,
      required this.onPick,
      required this.onExample,
      required this.onMakeCard});

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
                  'stay. Bring a .ohcourse file, make cards of your own, or '
                  'try an example to see how one works.',
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
                  onPressed: onMakeCard,
                  icon: const Icon(Icons.style_outlined),
                  label: const Text('Make a card')),
              const SizedBox(height: 12),
              TextButton.icon(
                  onPressed: onExample,
                  icon: const Icon(Icons.spa_outlined),
                  label: const Text('Try an example course')),
            ],
          ),
        ),
      ),
    );
  }
}
