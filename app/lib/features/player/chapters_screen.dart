/// The chapters drawer (ADR-0013, Campaign 7): every chapter across an
/// audiobook's files, tap to jump. Mirrors `captures_screen.dart`'s shape
/// — a Navigator-pushed list, not a bottom sheet, matching the other
/// list-of-moments doors ([QueueScreen], [CapturesScreen]) rather than the
/// short-lived controls in [SleepTimerSheet].
library;

import 'package:flutter/material.dart';

import '../../db/database.dart';
import 'audiobook_chapters.dart';
import 'player_controller.dart';

class ChaptersScreen extends StatefulWidget {
  final PlayerController controller;
  final Work work;
  final List<AudiobookFileRow> files;

  /// Injectable so tests never touch a real filesystem — the shell wires
  /// [readAudiobookChapterPrefix].
  final List<AudiobookChapter> Function(List<AudiobookFileRow>) computeChapters;

  const ChaptersScreen({
    super.key,
    required this.controller,
    required this.work,
    required this.files,
    required this.computeChapters,
  });

  @override
  State<ChaptersScreen> createState() => _ChaptersScreenState();
}

class _ChaptersScreenState extends State<ChaptersScreen> {
  List<AudiobookChapter>? _chapters;

  @override
  void initState() {
    super.initState();
    // Box-parsing a handful of local files is fast, but never worth
    // blocking the first frame for — computed after the initial build,
    // same reasoning as every other screen's async _load().
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _load() {
    final chapters = widget.computeChapters(widget.files);
    if (!mounted) return;
    setState(() => _chapters = chapters);
  }

  Future<void> _jump(AudiobookChapter c) async {
    await widget.controller.playAudiobookAt(
      widget.work,
      fileIdx: c.fileIdx,
      positionMs: c.startMs,
    );
  }

  @override
  Widget build(BuildContext context) {
    final chapters = _chapters;
    return Scaffold(
      appBar: AppBar(
        title: Text('Chapters — ${widget.work.title}',
            overflow: TextOverflow.ellipsis, maxLines: 1),
      ),
      body: chapters == null
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: chapters.length,
              itemBuilder: (context, i) {
                final c = chapters[i];
                final current = widget.controller.isAudiobook &&
                    widget.controller.currentFileIdx == c.fileIdx;
                return ListTile(
                  key: Key('chapter-$i'),
                  leading: current
                      ? const Icon(Icons.play_arrow)
                      : const SizedBox(width: 24),
                  title: Text(c.title),
                  onTap: () => _jump(c),
                );
              },
            ),
    );
  }
}
