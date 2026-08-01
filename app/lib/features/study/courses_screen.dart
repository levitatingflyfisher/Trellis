import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:study_core/study_core.dart' as study;

import '../../db/database.dart';
import '../brain/brain_settings_screen.dart';
import '../brain/brain_store.dart';
import '../intake/paste_intake.dart' show epochDayUtcNow;
import 'course_import.dart';
import 'course_map_screen.dart';
import 'daily_review_screen.dart';

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

  /// Campaign 4 Phase 5: opens Trellis Echo, the reader's own private
  /// year-in-review — same door-not-navigation shape as [onOpenBackup].
  /// Never PIN-gated: that's ParentDashboardScreen's, a different
  /// audience (a parent reviewing a household, not a reader reviewing
  /// themselves).
  final VoidCallback? onOpenEcho;

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
      this.onOpenEcho,
      this.brainStore,
      this.localMlAvailable});

  @override
  State<CoursesScreen> createState() => _CoursesScreenState();
}

class _CoursesScreenState extends State<CoursesScreen> {
  List<_Entry>? _entries;

  /// The study crown's home surface (Phase 1): daily review's OWN due
  /// count, separate from any course's — null while loading, 0 hides the
  /// chip entirely (quiet means quiet, ADR-0003 law 5: no permanent zero).
  int? _dailyReviewDue;

  /// The profile's scheduler choice ('classic' the default, or 'fsrs') —
  /// the study crown's toggle. Loaded once per [_load]; grading itself
  /// reads it fresh from the database (study_session_screen.dart), so this
  /// field only drives the settings menu's own checkmark.
  String _scheduler = 'classic';

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
    final scheduler = await widget.db.profilesDao.scheduler(widget.profile.id);
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _dailyReviewDue = due;
      _scheduler = scheduler;
    });
  }

  Future<void> _openDailyReview() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) =>
            DailyReviewScreen(db: widget.db, profileId: widget.profile.id)));
    await _load(); // the due count moved
  }

  /// The study crown's toggle (ADR-0009). Switching TO FSRS is the
  /// direction with a real, easy-to-miss consequence (the lossy-switch-
  /// back law), so it asks first, in one honest sentence naming what
  /// actually changes — never just "are you sure?". Switching BACK to
  /// Classic is an instant resume: there is nothing new to warn about in
  /// that direction, so it flips with no dialog, matching the reader's own
  /// settings-escape idiom (ADR-0006's `_toggleVoicePreference`).
  Future<void> _toggleScheduler() async {
    final next = _scheduler == 'fsrs' ? 'classic' : 'fsrs';
    if (next == 'fsrs') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Use FSRS for grading?'),
          content: const Text(
              'FSRS learns each card\'s own difficulty and memory curve to '
              'schedule reviews more precisely than Classic\'s fixed steps; '
              'switching back to Classic later resumes right where Classic '
              'left off, but FSRS\'s own progress won\'t carry over.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: const Text('Not now')),
            FilledButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: const Text('Use FSRS')),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await widget.db.profilesDao.setScheduler(widget.profile.id, next);
    if (!mounted) return;
    setState(() => _scheduler = next);
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
          // Campaign 9 Phase 1: a bare sparkles icon with no word read as
          // meaningless ("the sparkles meaning echo? what's an echo?").
          // Measured at 320dp/2x textScale with every other AppBar action
          // wired (the worst case) before choosing this over the
          // icon-only fallback — it fits.
          if (widget.onOpenEcho != null)
            TextButton.icon(
              key: const Key('open-echo'),
              onPressed: widget.onOpenEcho,
              icon: const Icon(Icons.auto_awesome_outlined),
              label: const Text('Echo'),
            ),
          PopupMenuButton<String>(
            key: const Key('study-settings'),
            tooltip: 'Study settings',
            onSelected: (value) {
              if (value == 'scheduler') unawaited(_toggleScheduler());
            },
            itemBuilder: (_) => [
              CheckedPopupMenuItem<String>(
                key: const Key('scheduler-toggle'),
                value: 'scheduler',
                checked: _scheduler == 'fsrs',
                child: const Text('FSRS scheduler (beta)'),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: (entries == null || entries.isEmpty)
          ? null
          : FloatingActionButton.extended(
              onPressed: _addSheet,
              icon: const Icon(Icons.add),
              label: const Text('Add')),
      body: Column(
        children: [
          if ((_dailyReviewDue ?? 0) > 0) _dailyReviewChip(),
          Expanded(
            child: switch (entries) {
              null => const Center(child: CircularProgressIndicator()),
              [] => _EmptyState(
                  onPaste: _paste, onPick: _pickFile, onStarter: _addStarter),
              _ => ListView.builder(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: entries.length,
                  itemBuilder: (_, i) => _courseTile(entries[i]),
                ),
            },
          ),
        ],
      ),
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
