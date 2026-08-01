/// The "Translate to Spanish" batch action (ADR-0008 "Babel" Phase 3): a
/// cancellable, resumable run over one work's sentences.
///
/// Resumability is free — the [TranslationSentence] store itself IS the
/// checkpoint. Unlike transcription (jobs_core's [JobRunner] over a
/// JobsTable row, needed because whisper's decode isn't naturally chunked
/// into a persisted artifact until a whole window completes), a
/// translated sentence is durable the instant it's written, so re-running
/// this same action after a cancel, a crash, or simply reopening the work
/// picks up exactly where it left off by asking the store what's already
/// there — no separate job-tracking row, nothing to garbage-collect.
library;

import 'package:flutter/foundation.dart';

import '../../../db/database.dart';
import 'sentence_units.dart';

enum TranslationJobPhase { idle, running, done, cancelled }

/// One progress beat: [doneUnits] counts sentences PROCESSED — already
/// stored, newly translated, or failed and skipped — out of [totalUnits],
/// the honest "how far through the work" number a progress bar shows.
class TranslationJobState {
  final TranslationJobPhase phase;
  final int doneUnits;
  final int totalUnits;
  const TranslationJobState(
      {required this.phase, required this.doneUnits, required this.totalUnits});
}

/// Runs [units] against [translate], persisting each result through [dao].
/// [translate] is a plain function — never `MarianTranslator` itself —
/// so a test drives this with a deterministic fake and never touches
/// `flutter_onnxruntime` or a platform channel; production callers pass
/// a resolved `MarianTranslator`'s own `translate` method.
class TranslationJobController extends ChangeNotifier {
  final SpineDao dao;
  final int workId;
  final List<TranslatableSentence> units;
  final Future<String> Function(String sentence) translate;
  final String lang;

  /// The chunked-request path (Campaign 8 "Babel widens" Phase 5): when
  /// set, [start] groups not-already-stored units into [chunkSize]-sized
  /// batches and calls this ONCE per batch instead of calling [translate]
  /// once per sentence — the whole point of a Brain-backed translator,
  /// where one request covering 10-20 sentences is dramatically cheaper
  /// than 10-20 separate ones. [translate] is still required (kept
  /// non-nullable so every existing Marian call site compiles unchanged)
  /// but is never invoked while this is set. A `null` at position `i` in
  /// the returned list fails closed for JUST that sentence (the fallback
  /// law, same as a thrown [translate]); the whole batch call throwing
  /// fails closed for every sentence in that ONE chunk, never the whole
  /// episode — the next chunk still runs.
  final Future<List<String?>> Function(List<String> sentences)? translateBatch;

  /// Sentences per [translateBatch] request — the spec's own "10-20 per
  /// request" range; unused on the (default) per-sentence path.
  final int chunkSize;

  /// Which engine wrote this run's rows (Campaign 8 "Babel widens" Phase
  /// 5) — `'marian'` by default; a Brain-lane caller (`BrainTranslator`)
  /// names itself instead (`'domovoi:stove'`, `'domovoi:byok:<provider>'`,
  /// ...). Stored verbatim on every row this run writes
  /// ([TranslationSentences.engine]) — provenance only, read nowhere in
  /// this controller's own logic.
  final String engine;

  TranslationJobController({
    required this.dao,
    required this.workId,
    required this.units,
    required this.translate,
    this.translateBatch,
    this.chunkSize = 15,
    this.lang = 'es',
    this.engine = 'marian',
  }) : _state = TranslationJobState(
            phase: TranslationJobPhase.idle,
            doneUnits: 0,
            totalUnits: units.length);

  TranslationJobState _state;
  TranslationJobState get state => _state;

  bool _cancelRequested = false;

  void _setState(TranslationJobState s) {
    _state = s;
    notifyListeners();
  }

  /// Cancels the run at the next sentence boundary — whatever is already
  /// persisted stays. Calling this before [start] or after it has already
  /// finished has no effect.
  void cancel() => _cancelRequested = true;

  /// Runs to completion or cancellation. Already-stored sentences (whose
  /// stored `sourceText` still matches the CURRENT sentence — the store's
  /// staleness law, [translatedTextFor]) are skipped without calling
  /// [translate]; a stale row (source text changed under it) is
  /// re-translated like any other missing sentence. A [translate] failure
  /// on one sentence stores nothing for that index (the fallback law —
  /// the reader falls back to English for it) and the run continues.
  ///
  /// [translateBatch], when set, takes over entirely — see its own doc
  /// comment; [translate] is never called on that path.
  Future<void> start() async {
    if (translateBatch != null) return _startBatched(translateBatch!);

    _cancelRequested = false;
    final stored = await dao.translationSentencesOf(workId, lang: lang);
    var done = 0;
    _setState(TranslationJobState(
        phase: TranslationJobPhase.running,
        doneUnits: done,
        totalUnits: units.length));

    for (final u in units) {
      if (_cancelRequested) {
        _setState(TranslationJobState(
            phase: TranslationJobPhase.cancelled,
            doneUnits: done,
            totalUnits: units.length));
        return;
      }
      final already = translatedTextFor(
              stored: stored,
              segIdx: u.segIdx,
              sentenceIdx: u.sentenceIdx,
              currentSourceText: u.text) !=
          null;
      if (!already) {
        try {
          final body = await translate(u.text);
          await dao.upsertTranslationSentence(
              workId: workId,
              segmentIdx: u.segIdx,
              sentenceIdx: u.sentenceIdx,
              lang: lang,
              sourceText: u.text,
              body: body,
              engine: engine);
        } catch (_) {
          // The fallback law: nothing stored for this index, keep going.
        }
      }
      done++;
      _setState(TranslationJobState(
          phase: TranslationJobPhase.running,
          doneUnits: done,
          totalUnits: units.length));
    }

    _setState(TranslationJobState(
        phase: TranslationJobPhase.done,
        doneUnits: done,
        totalUnits: units.length));
  }

  /// The chunked-request path. Groups not-already-stored units into
  /// [chunkSize]-sized chunks, in the SAME order [units] is in, and calls
  /// [batchFn] once per chunk. A chunk boundary is the only point cancel
  /// is checked — the smallest atomic round trip on this path, the same
  /// way the per-sentence path checks between individual [translate]
  /// calls; there is no meaningful way to half-cancel one in-flight
  /// request. `null` at a chunk position fails closed for just that
  /// sentence (nothing stored, English falls through); the whole call
  /// throwing fails closed for every sentence in that ONE chunk — never
  /// the whole episode — and the next chunk still runs.
  Future<void> _startBatched(
      Future<List<String?>> Function(List<String> sentences) batchFn) async {
    _cancelRequested = false;
    final stored = await dao.translationSentencesOf(workId, lang: lang);
    var done = 0;
    _setState(TranslationJobState(
        phase: TranslationJobPhase.running,
        doneUnits: done,
        totalUnits: units.length));

    var i = 0;
    while (i < units.length) {
      if (_cancelRequested) {
        _setState(TranslationJobState(
            phase: TranslationJobPhase.cancelled,
            doneUnits: done,
            totalUnits: units.length));
        return;
      }

      final chunk = <TranslatableSentence>[];
      while (chunk.length < chunkSize && i < units.length) {
        final u = units[i];
        i++;
        final already = translatedTextFor(
                stored: stored,
                segIdx: u.segIdx,
                sentenceIdx: u.sentenceIdx,
                currentSourceText: u.text) !=
            null;
        if (already) {
          done++;
          _setState(TranslationJobState(
              phase: TranslationJobPhase.running,
              doneUnits: done,
              totalUnits: units.length));
          continue;
        }
        chunk.add(u);
      }
      if (chunk.isEmpty) continue; // only already-stored units remained

      List<String?> results;
      try {
        results = await batchFn([for (final u in chunk) u.text]);
      } catch (_) {
        // The fallback law, at chunk granularity: nothing stored for any
        // sentence in THIS chunk, keep going with the next one.
        results = List<String?>.filled(chunk.length, null);
      }
      for (var k = 0; k < chunk.length; k++) {
        final body = k < results.length ? results[k] : null;
        if (body != null) {
          await dao.upsertTranslationSentence(
              workId: workId,
              segmentIdx: chunk[k].segIdx,
              sentenceIdx: chunk[k].sentenceIdx,
              lang: lang,
              sourceText: chunk[k].text,
              body: body,
              engine: engine);
        }
        done++;
        _setState(TranslationJobState(
            phase: TranslationJobPhase.running,
            doneUnits: done,
            totalUnits: units.length));
      }
    }

    _setState(TranslationJobState(
        phase: TranslationJobPhase.done,
        doneUnits: done,
        totalUnits: units.length));
  }
}
