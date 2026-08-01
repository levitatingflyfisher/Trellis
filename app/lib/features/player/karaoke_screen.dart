/// Synced text — the karaoke view (P3, the canonical user's payoff).
///
/// When a work has alignments, playback and text are the same cursor
/// projected two ways (ADR-0002): the segment holding the playhead is lit,
/// tapping any segment seeks the audio to its start, and inside the lit
/// segment each word lights up on its own best-effort timing when the
/// engine produced word stamps — sentence-level is the guarantee, and the
/// view quietly falls back to it.
library;

import 'package:flutter/material.dart';
import 'package:loom_core/loom_core.dart' as core;

import '../../db/database.dart';
import '../reader/reader_logic.dart' show ledgerWord;
import '../reader/reader_screen.dart' show ReaderScreen;
import '../reader/speech/speech_engine.dart';
import '../reader/speech/speech_temp_files.dart';
import '../reader/translation/marian_engine.dart';
import '../../services/device_services.dart' show TtsSpeaker;
import '../transcribe/transcript_writer.dart' show decodeWordTimingBlob;
import 'player_controller.dart';

class KaraokeScreen extends StatefulWidget {
  final AppDatabase db;
  final PlayerController controller;
  final Work work;

  /// The speak-mode voice, handed on to the reader "Read from here" opens —
  /// see `LibraryScreen.tts`. Null lets that reader fall back to the
  /// platform speaker, the same as any other call site that doesn't wire
  /// one.
  final TtsSpeaker? tts;

  /// Resolves the neural voice for the reader "Read from here" opens
  /// (ADR-0006) — see `LibraryScreen.resolveSpeechEngine`. Null keeps that
  /// reader on the system voice.
  final Future<SynthesisSpeechEngine?> Function({String? lang})?
      resolveSpeechEngine;

  /// Where the reader "Read from here" opens writes per-sentence WAV temp
  /// files while speaking neurally — see
  /// `LibraryScreen.createSpeechTempFiles`.
  final SpeechTempFiles Function()? createSpeechTempFiles;

  /// Resolves a translator for a specific (source, target) pair (Campaign
  /// 8 "Babel widens" Phase 1, generalizing ADR-0008 "Babel" Phase 3) for
  /// the reader "Read from here" opens — see
  /// `LibraryScreen.resolveTranslator`. Null keeps that reader without a
  /// "Translate…" action, the same built-but-unreachable gap library/
  /// river-opened readers had before that threading landed; this closes
  /// the SAME gap for this third entry point.
  final Future<MarianTranslator?> Function(
      {required String sourceLang, required String targetLang})?
      resolveTranslator;

  /// The picker's own data source, threaded the same way — see
  /// `LibraryScreen.availableTranslationTargets`.
  final Future<List<String>> Function({required String sourceLang})?
      availableTranslationTargets;

  const KaraokeScreen(
      {super.key,
      required this.db,
      required this.controller,
      required this.work,
      this.tts,
      this.resolveSpeechEngine,
      this.createSpeechTempFiles,
      this.resolveTranslator,
      this.availableTranslationTargets});

  @override
  State<KaraokeScreen> createState() => _KaraokeScreenState();
}

class _SegmentRow {
  final int idx;
  final String text;
  final int? tStartMs;
  final int? tEndMs;
  final List<List<Object>> words; // [word, t0, t1]
  _SegmentRow(
      {required this.idx,
      required this.text,
      required this.tStartMs,
      required this.tEndMs,
      required this.words});
}

class _KaraokeScreenState extends State<KaraokeScreen> {
  List<_SegmentRow>? _rows;
  core.Spine? _spine;
  final Map<int, GlobalKey> _keys = {};
  int _lastLit = -1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final segments = await widget.db.spineDao.segmentsOf(widget.work.id);
    final alignments = await widget.db.spineDao.alignmentsOf(widget.work.id);
    final byIdx = {for (final a in alignments) a.segmentIdx: a};
    final rows = [
      for (final s in segments)
        _SegmentRow(
          idx: s.idx,
          text: s.body,
          tStartMs: byIdx[s.idx]?.tStartMs,
          tEndMs: byIdx[s.idx]?.tEndMs,
          words: byIdx[s.idx]?.wordTimings == null
              ? const []
              : decodeWordTimingBlob(byIdx[s.idx]!.wordTimings!),
        )
    ];
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _spine = core.Spine(segments: const [], layers: const [], alignments: [
        for (final a in alignments)
          core.Alignment(
              segmentIdx: a.segmentIdx,
              tStartMs: a.tStartMs,
              tEndMs: a.tEndMs)
      ]);
    });
  }

  int _litSegment() {
    final spine = _spine;
    if (spine == null || spine.alignments.isEmpty) return -1;
    return spine
        .positionAtAudioTime(widget.controller.position.inMilliseconds)
        .segmentIdx;
  }

  void _followPlayback(int lit) {
    if (lit == _lastLit || lit < 0) return;
    _lastLit = lit;
    if (!widget.controller.playing) return;
    final key = _keys[lit];
    final ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          alignment: 0.3, duration: const Duration(milliseconds: 300));
    }
  }

  /// "Read from here": the reverse of the reader's "Listen from here". A
  /// live playback time isn't itself the cursor law's currency — a
  /// Position row is — so this writes through the SAME row the reader
  /// already loads via [PlayerController.saveProgress] (no second store)
  /// and then opens the reader, which picks the row up in its own [_load].
  Future<void> _readFromHere() async {
    await widget.controller.saveProgress();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ReaderScreen(
            db: widget.db,
            profileId: widget.work.profileId,
            work: widget.work,
            player: widget.controller,
            tts: widget.tts,
            resolveSpeechEngine: widget.resolveSpeechEngine,
            createSpeechTempFiles: widget.createSpeechTempFiles,
            resolveTranslator: widget.resolveTranslator,
            availableTranslationTargets: widget.availableTranslationTargets)));
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.work.title,
            overflow: TextOverflow.ellipsis, maxLines: 1),
        actions: [
          IconButton(
            key: const Key('read-from-here'),
            tooltip: 'Read from here',
            icon: const Icon(Icons.chrome_reader_mode_outlined),
            onPressed: _readFromHere,
          ),
        ],
      ),
      body: rows == null
          ? const Center(child: CircularProgressIndicator())
          : ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) {
                final lit = _litSegment();
                WidgetsBinding.instance
                    .addPostFrameCallback((_) => _followPlayback(lit));
                return ListView(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 16),
                  children: [
                    for (final row in rows) _segment(row, lit),
                    const SizedBox(height: 80),
                  ],
                );
              },
            ),
    );
  }

  Widget _segment(_SegmentRow row, int lit) {
    final theme = Theme.of(context);
    final isLit = row.idx == lit;
    final aligned = row.tStartMs != null;

    Widget child;
    if (isLit && row.words.isNotEmpty) {
      child = _wordWrap(row);
    } else {
      child = Text(
        row.text,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: aligned
              ? (isLit ? theme.colorScheme.onSurface : null)
              : theme.colorScheme.outline,
          fontWeight: isLit ? FontWeight.w600 : null,
        ),
      );
    }

    return GestureDetector(
      key: _keys.putIfAbsent(row.idx, GlobalKey.new),
      behavior: HitTestBehavior.opaque,
      onTap: aligned
          ? () => widget.controller
              .seekTo(Duration(milliseconds: row.tStartMs!))
          : null,
      child: Container(
        key: Key('karaoke-seg-${row.idx}'),
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        decoration: isLit
            ? BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8))
            : null,
        child: child,
      ),
    );
  }

  /// Keeps a long-pressed word in the listener's ledger — the same dao path
  /// the reader uses, so dedupe stays in the schema; the work row carries
  /// the profile (a work belongs to exactly one reader) and the language.
  Future<void> _keepWord(String token) async {
    final word = ledgerWord(token);
    if (word == null) return;
    await widget.db.ledgerDao.add(
        profileId: widget.work.profileId,
        word: word,
        lang: widget.work.lang,
        sourceWorkId: widget.work.id,
        nowMs: DateTime.now().millisecondsSinceEpoch);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
          SnackBar(content: Text('“$word” is in your word ledger.')));
  }

  /// Word-level best-effort: the word whose stamp holds the playhead leads;
  /// tapping any word seeks to that word's own start, holding it keeps it.
  Widget _wordWrap(_SegmentRow row) {
    final theme = Theme.of(context);
    final tMs = widget.controller.position.inMilliseconds;
    var litWord = -1;
    for (var i = 0; i < row.words.length; i++) {
      if ((row.words[i][1] as int) <= tMs) litWord = i;
    }
    final base = theme.textTheme.bodyLarge;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (var i = 0; i < row.words.length; i++)
          GestureDetector(
            onTap: () => widget.controller
                .seekTo(Duration(milliseconds: row.words[i][1] as int)),
            onLongPress: () => _keepWord(row.words[i][0] as String),
            child: i == litWord
                ? Container(
                    key: Key('karaoke-word-${row.idx}-$i'),
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                        color: theme.colorScheme.tertiaryContainer,
                        borderRadius: BorderRadius.circular(4)),
                    child: Text(row.words[i][0] as String,
                        style:
                            base?.copyWith(fontWeight: FontWeight.w700)),
                  )
                : Text(row.words[i][0] as String, style: base),
          ),
      ],
    );
  }
}
