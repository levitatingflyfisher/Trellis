/// A course's cards, step by step, from its map: tap a card to change it,
/// Add card to make one. Front and back cards and cloze cards are made
/// and changed here; the other two kinds (choice and steps) come only
/// from course files, and say so.
library;

import 'package:flutter/material.dart';
import 'package:study_core/study_core.dart' as study;

import '../../db/database.dart';
import '../shared/capped_body.dart';
import 'card_editing.dart';
import 'card_editor_screen.dart';
import 'card_store.dart';

/// How a card is listed: a cloze as it is asked, with its blanks.
String cardListText(study.RetrievalItem item) => switch (item) {
      study.ClozeItem(:final text) =>
        text.replaceAll(RegExp(r'\{\{c\d+::[^}]*\}\}'), '____'),
      study.QaItem(:final prompt) => prompt,
      study.DiscriminationItem(:final prompt) => prompt,
      study.ProcedureItem(:final prompt) => prompt,
    };

String _kindName(study.RetrievalItem item) => switch (item) {
      study.ClozeItem() => 'Cloze',
      study.QaItem() => 'Front and back',
      study.DiscriminationItem() => 'Choice',
      study.ProcedureItem() => 'Steps',
    };

class CourseCardsScreen extends StatefulWidget {
  const CourseCardsScreen(
      {super.key, required this.db, required this.courseRowId});

  final AppDatabase db;
  final int courseRowId;

  @override
  State<CourseCardsScreen> createState() => _CourseCardsScreenState();
}

class _CourseCardsScreenState extends State<CourseCardsScreen> {
  study.Course? _course;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final row = await widget.db.studyDao.courseRowById(widget.courseRowId);
    if (row == null || !mounted) return;
    setState(() => _course = study.parseCourseString(row.raw));
  }

  List<({String id, String title})> get _steps => [
        for (final n in _course!.nodes) (id: n.id, title: n.title),
      ];

  Future<void> _add() async {
    final saved = await showCardEditor(context,
        title: 'Add card',
        steps: _steps,
        onSave: (draft, step) => addCard(widget.db, widget.courseRowId,
            nodeId: step ?? _course!.nodes.first.id, draft: draft));
    if (saved) await _load();
  }

  Future<void> _edit(study.RetrievalItem item) async {
    final draft = draftOf(item);
    if (draft == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
            content: Text('A choice or steps card is changed in the course '
                'file it came from.')));
      return;
    }
    final changed = await showCardEditor(context,
        title: 'Edit card',
        initial: draft,
        onSave: (d, _) => editCard(widget.db, widget.courseRowId, item.id, d),
        onDelete: () => deleteCard(widget.db, widget.courseRowId, item.id));
    if (changed) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final course = _course;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(course == null ? 'Cards' : 'Cards: ${course.title}')),
      floatingActionButton: course == null
          ? null
          : FloatingActionButton.extended(
              key: const Key('add-card'),
              tooltip: 'Add a card to this course',
              onPressed: _add,
              icon: const Icon(Icons.add),
              label: const Text('Add card')),
      body: CappedBody(
              child: course == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                padding: const EdgeInsets.only(bottom: 88),
                children: [
                  for (final n in course.nodes) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                      child: Text(n.title, style: theme.textTheme.titleSmall),
                    ),
                    for (final item in n.items)
                      ListTile(
                        key: Key('card-${item.id}'),
                        title: Text(cardListText(item),
                            maxLines: 3, overflow: TextOverflow.ellipsis),
                        subtitle: Text(_kindName(item)),
                        trailing: draftOf(item) == null
                            ? null
                            : const Icon(Icons.edit_outlined),
                        onTap: () => _edit(item),
                      ),
                  ],
                ],
              ),
            ),
    );
  }
}
