/// Captures — the study crown, Phase 2's list door. A capture is a moment
/// saved with one tap during listening; each row shows the sentence it
/// snapped to (±1 sentence of context, sentence-level being the alignment
/// guarantee — ADR-0002), or an honest "transcript pending" line when the
/// work had none yet at capture time (see [CapturesDao.backfillForWork]).
/// Tapping a row jumps playback to the capture's own exact position — no
/// projection needed here, unlike the cross-work read<->listen handoff:
/// the raw millisecond IS the ground truth within the same episode.
library;

import 'package:flutter/material.dart';

import '../../db/database.dart';
import 'player_controller.dart';

class CapturesScreen extends StatefulWidget {
  final AppDatabase db;
  final PlayerController controller;
  final Work work;
  const CapturesScreen(
      {super.key, required this.db, required this.controller, required this.work});

  @override
  State<CapturesScreen> createState() => _CapturesScreenState();
}

class _CapturesScreenState extends State<CapturesScreen> {
  List<CaptureRow>? _captures;
  Map<int, String>? _textByIdx;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final captures = await widget.db.capturesDao.capturesOf(widget.work.id);
    final segments = await widget.db.spineDao.segmentsOf(widget.work.id);
    if (!mounted) return;
    setState(() {
      _captures = captures;
      _textByIdx = {for (final s in segments) s.idx: s.body};
    });
  }

  /// The ±1-sentence context around a bound capture; an honest line when
  /// there is nothing to bind to yet.
  String _context(CaptureRow c) {
    final byIdx = _textByIdx;
    final segmentIdx = c.segmentIdx;
    if (segmentIdx == null || byIdx == null) {
      final seconds = c.positionMs ~/ 1000;
      // Campaign 7 (ADR-0013): an audiobook capture without a transcript
      // is the permanent state (Phase 1/2 build no alignments for one),
      // so this line names the file too — "transcript pending" alone
      // would be misleading for a book that has none coming.
      final fileIdx = c.fileIdx;
      if (fileIdx != null) {
        return 'File ${fileIdx + 1}, ${seconds}s in.';
      }
      return 'Captured at ${seconds}s — transcript pending.';
    }
    final parts = [
      for (final i in [segmentIdx - 1, segmentIdx, segmentIdx + 1])
        if (byIdx.containsKey(i)) byIdx[i]!
    ];
    return parts.join(' ');
  }

  Future<void> _jump(CaptureRow c) async {
    // Campaign 7 (ADR-0013): a multi-file audiobook capture names its OWN
    // file — playWork's plain resume-then-seek shape has no way to land
    // on a file other than wherever the book was last playing.
    final fileIdx = c.fileIdx;
    if (widget.work.kind == 'audiobook' && fileIdx != null) {
      await widget.controller.playAudiobookAt(widget.work,
          fileIdx: fileIdx, positionMs: c.positionMs);
      return;
    }
    if (widget.controller.current?.id != widget.work.id) {
      await widget.controller.playWork(widget.work);
    }
    await widget.controller.seekTo(Duration(milliseconds: c.positionMs));
  }

  @override
  Widget build(BuildContext context) {
    final captures = _captures;
    return Scaffold(
      appBar: AppBar(
        title: Text('Captures — ${widget.work.title}',
            overflow: TextOverflow.ellipsis, maxLines: 1),
      ),
      body: captures == null
          ? const Center(child: CircularProgressIndicator())
          : captures.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                        'Nothing captured yet — tap the bookmark on the '
                        'player to keep a moment.',
                        style: Theme.of(context).textTheme.bodyLarge,
                        textAlign: TextAlign.center),
                  ),
                )
              : ListView.builder(
                  itemCount: captures.length,
                  itemBuilder: (context, i) {
                    final c = captures[i];
                    return ListTile(
                      key: Key('capture-${c.id}'),
                      title: Text(_context(c)),
                      onTap: () => _jump(c),
                    );
                  },
                ),
    );
  }
}
