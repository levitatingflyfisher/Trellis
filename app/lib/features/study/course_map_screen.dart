import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:study_core/study_core.dart' as study;

import '../../db/database.dart' hide Alignment;
import '../intake/paste_intake.dart' show epochDayUtcNow;
import 'anki_export.dart';
import 'study_session_screen.dart';
import 'wall/espalier_wall.dart';

/// Writes [bytes] where the user's picker points. Mobile pickers write the
/// bytes themselves; desktop ones only return a path — cover both. Returns
/// false when the picker is dismissed (a no is a no, donor-consent style).
Future<bool> _pickAndSaveApkg(String fileName, Uint8List bytes) async {
  final path = await FilePicker.platform
      .saveFile(fileName: fileName, type: FileType.any, bytes: bytes);
  if (path == null) return false;
  final file = File(path);
  if (!await file.exists() || await file.length() == 0) {
    await file.writeAsBytes(bytes);
  }
  return true;
}

/// The course map: the prerequisite DAG as the Espalier Wall (proposal-2
/// §12), every state derived fresh from the card rows (never stored) — so
/// finishing a session IS the unlock recompute. Locked buds sit further up
/// the lattice than what earns them; mastered fruits are ripe terracotta
/// and carry their check; due chips ride only on fruits a session can
/// actually present.
class CourseMapScreen extends StatefulWidget {
  final AppDatabase db;
  final CourseRow courseRow;
  final study.Course course;

  /// The `.apkg` save seam: tests write into a temp dir; the app defaults
  /// to the system save picker. Never a real picker under test.
  final Future<bool> Function(String fileName, Uint8List bytes)? saveApkg;
  const CourseMapScreen(
      {super.key,
      required this.db,
      required this.courseRow,
      required this.course,
      this.saveApkg});

  @override
  State<CourseMapScreen> createState() => _CourseMapScreenState();
}

class _CourseMapScreenState extends State<CourseMapScreen> {
  Map<String, study.CardState>? _cards;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final cards = await widget.db.studyDao.loadCardStates(widget.courseRow.id);
    if (!mounted) return;
    setState(() => _cards = cards);
  }

  /// One tap -> a real `.apkg` through the save seam. The whole course
  /// travels (Anki gates nothing; the ladder survives as subdecks + tags),
  /// and scheduling stays home — Anki/FSRS owns it over there.
  Future<void> _exportAnki() async {
    final name = apkgFileName(widget.course);
    final bytes = await buildApkgBytes(widget.course);
    final saved =
        await (widget.saveApkg ?? _pickAndSaveApkg)(name, bytes);
    if (!mounted || !saved) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved $name — import it in Anki.')));
  }

  /// Hidden where the builder cannot run (web) — never shown-then-broken.
  List<Widget> get _actions => [
        if (ankiExportSupported)
          IconButton(
              key: const Key('export-anki'),
              tooltip: 'Export to Anki',
              icon: const Icon(Icons.ios_share_outlined),
              onPressed: _exportAnki),
      ];

  Future<void> _study() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => StudySessionScreen(
          db: widget.db,
          courseRowId: widget.courseRow.id,
          course: widget.course),
    ));
    if (!mounted) return;
    await _reload(); // mastery moved — recompute every unlock from the cards
  }

  @override
  Widget build(BuildContext context) {
    final cards = _cards;
    if (cards == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.course.title), actions: _actions),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final theme = Theme.of(context);
    final course = widget.course;
    final today = epochDayUtcNow();

    // One progress pass, reused for totals, the wall and unlock checks.
    final progressByNode = {
      for (final n in course.nodes) n.id: study.nodeProgress(n, cards, today),
    };
    final wallStates = <String, WallNodeState>{};
    var totalDue = 0;
    var totalItems = 0;
    var totalMastered = 0;
    for (final n in course.nodes) {
      final p = progressByNode[n.id]!;
      // Count only due cards a session can present: a node both unstarted
      // and locked contributes nothing to the queue, so it must not inflate
      // the declared size (ADR-0003 law 3 — the declaration is honest).
      // A locked-but-started node stays studyable: a prerequisite lapse
      // never buries reviews the learner already owns.
      final started = n.items.any((it) => cards[it.id] != null);
      final studyable = started || study.nodeUnlockedFrom(n, progressByNode);
      if (studyable) totalDue += p.due;
      totalItems += p.total;
      totalMastered += p.mastered;
      wallStates[n.id] = WallNodeState(
          mastery: p.mastery, due: p.due, studyable: studyable);
    }
    final overall = totalItems == 0 ? 0.0 : totalMastered / totalItems;

    return Scaffold(
      appBar: AppBar(title: Text(widget.course.title), actions: _actions),
      floatingActionButton: totalDue == 0
          ? null
          : FloatingActionButton.extended(
              key: const Key('study-fab'),
              onPressed: _study,
              icon: const Icon(Icons.psychology_alt_outlined),
              label: Text('Study · $totalDue due')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (course.description.isNotEmpty) ...[
            Text(course.description, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 16),
          ],
          // An additive lifetime stat (ADR-0003 law 5): what has been built.
          Text('Mastery ${(overall * 100).round()}%',
              style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: overall, minHeight: 8),
          ),
          const SizedBox(height: 20),
          Text('The espalier', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          EspalierWall(
            course: course,
            states: wallStates,
            onStudy: _study,
          ),
          const SizedBox(height: 80),
        ],
      ),
    );
  }
}
