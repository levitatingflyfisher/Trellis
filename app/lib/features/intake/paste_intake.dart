import 'package:flutter/material.dart';
import 'package:loom_core/loom_core.dart' as core;

import '../../db/database.dart';

/// Whole-epoch-day UTC, the fleet's day arithmetic (study_core convention).
int epochDayUtcNow() =>
    DateTime.now().toUtc().millisecondsSinceEpoch ~/
    Duration.millisecondsPerDay;

/// Paste intake: text/markdown through the donor `parseTextFile` heuristics
/// into one spine work. Returns the new work id, or null on cancel/empty.
Future<int?> showPasteIntakeDialog(BuildContext context,
    {required AppDatabase db, required int profileId}) {
  return showDialog<int>(
    context: context,
    builder: (_) => _PasteDialog(db: db, profileId: profileId),
  );
}

class _PasteDialog extends StatefulWidget {
  final AppDatabase db;
  final int profileId;
  const _PasteDialog({required this.db, required this.profileId});

  @override
  State<_PasteDialog> createState() => _PasteDialogState();
}

class _PasteDialogState extends State<_PasteDialog> {
  final _title = TextEditingController();
  final _text = TextEditingController();

  @override
  void dispose() {
    _title.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final text = _text.text;
    if (text.trim().isEmpty) {
      Navigator.pop(context, null);
      return;
    }
    final title = _title.text.trim();
    final parsed = core.parseTextFile(text, title.isEmpty ? null : title);
    final workId = await widget.db.spineDao.insertWork(
        profileId: widget.profileId,
        kind: 'note',
        title: parsed.title,
        persistence: 'work',
        firstSeenEpochDay: epochDayUtcNow());
    await widget.db.spineDao.insertSegments(workId, [
      for (final s in parsed.segments)
        (idx: s.idx, kind: s.kind.name, text: s.text)
    ]);
    if (!mounted) return;
    Navigator.pop(context, workId);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Paste text'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('paste-title'),
              controller: _title,
              decoration:
                  const InputDecoration(labelText: 'Title (optional)'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('paste-text'),
              controller: _text,
              minLines: 4,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: 'Text or markdown',
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Cancel')),
        FilledButton(onPressed: _add, child: const Text('Add to library')),
      ],
    );
  }
}
