/// The Translate batch (ADR-0008 "Babel" Phase 3; any pair, and via
/// English, since 1.5.5): a cancellable, resumable run over one work's
/// sentences.
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
import 'marian_types.dart';
import 'sentence_units.dart';
import 'translator.dart';

/// [failed]: a model that would not open; nothing ran.
enum TranslationJobPhase { idle, running, done, cancelled, failed }

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

  /// The text handed to [translate] for unit `u`, when it isn't `u.text`
  /// itself: a pivot's second pass translates the stored English, while
  /// the row it writes still names the original sentence as its source
  /// (the staleness law). Null skips the unit, storing nothing, the same
  /// fallback a failed sentence gets.
  final String? Function(TranslatableSentence u)? inputOf;

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
    required this.lang,
    this.inputOf,
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
      final input = already ? null : (inputOf == null ? u.text : inputOf!(u));
      if (input != null) {
        try {
          final body = await translate(input);
          await dao.upsertTranslationSentence(
              workId: workId,
              segmentIdx: u.segIdx,
              sentenceIdx: u.sentenceIdx,
              lang: lang,
              sourceText: u.text,
              body: body,
              engine: engine);
        } on MarianModelInitException {
          rethrow; // the model itself is broken: every sentence would fail
        } on MarianModelMissingFilesException {
          rethrow;
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


/// One pass of a [TranslationRun]: the language it writes, and how to
/// open the model that writes it. Opened only if the pass has anything
/// left to do, so a resumed pivot never loads its finished first leg.
class TranslationStep {
  final String lang;
  final Future<SentenceTranslator?> Function() open;
  const TranslationStep({required this.lang, required this.open});
}

/// A whole translation into [target]: one pass for a direct pair, two
/// via English (X->en, then en->Y over the stored English). Passes run
/// one after the other with one model resident at a time, each freed as
/// its pass ends.
///
/// The work's run marker ([SpineDao.setTranslationRunLang]) is set for
/// the length of the run and cleared when it finishes, is cancelled or
/// fails. A process the system kills leaves it set, and the reader
/// starts the same run again on the next open; the stored sentences are
/// the progress, so the new run picks up where the old one stopped.
class TranslationRun extends ChangeNotifier {
  final SpineDao dao;
  final int workId;
  final List<TranslatableSentence> units;
  final String target;
  final List<TranslationStep> steps;

  TranslationRun({
    required this.dao,
    required this.workId,
    required this.units,
    required this.target,
    required this.steps,
  }) : _state = TranslationJobState(
            phase: TranslationJobPhase.idle,
            doneUnits: 0,
            totalUnits: units.length * steps.length);

  TranslationJobState _state;

  /// Progress across every pass: a two-pass run over 100 sentences
  /// counts to 200. [pass] and [passDone] say where it is in words.
  TranslationJobState get state => _state;

  int _passIndex = 0;

  /// The pass running now, 0-based; [steps].length passes in all.
  int get pass => _passIndex;
  int get passCount => steps.length;

  /// Sentences done in the current pass, out of `units.length`.
  int get passDone =>
      (_state.doneUnits - _passIndex * units.length).clamp(0, units.length);

  TranslationJobController? _pass;
  bool _cancelled = false;
  bool _keepMarker = false;

  /// The reader's Cancel: stops at the next sentence and forgets the run.
  void cancel() {
    _cancelled = true;
    _pass?.cancel();
  }

  /// Leaving the reader: stops at the next sentence like [cancel], frees
  /// the model, but keeps the run marker so the next open resumes.
  void stop() {
    _keepMarker = true;
    cancel();
  }

  void _set(TranslationJobPhase phase, int done) {
    _state = TranslationJobState(
        phase: phase, doneUnits: done, totalUnits: _state.totalUnits);
    notifyListeners();
  }

  Future<void> start() async {
    await dao.setTranslationRunLang(workId, target);
    _set(TranslationJobPhase.running, 0);
    var before = 0;
    for (var i = 0; i < steps.length; i++) {
      _passIndex = i;
      final step = steps[i];
      final previous = i == 0
          ? null
          : await dao.translationSentencesOf(workId, lang: steps[i - 1].lang);
      String? inputOf(TranslatableSentence u) => previous == null
          ? u.text
          : translatedTextFor(
              stored: previous,
              segIdx: u.segIdx,
              sentenceIdx: u.sentenceIdx,
              currentSourceText: u.text);

      final stored = await dao.translationSentencesOf(workId, lang: step.lang);
      final pending = units.any((u) =>
          inputOf(u) != null &&
          translatedTextFor(
                  stored: stored,
                  segIdx: u.segIdx,
                  sentenceIdx: u.sentenceIdx,
                  currentSourceText: u.text) ==
              null);
      if (pending && !_cancelled) {
        SentenceTranslator? translator;
        try {
          translator = await step.open();
        } catch (_) {
          translator = null;
        }
        if (translator == null) {
          await dao.setTranslationRunLang(workId, null);
          _set(TranslationJobPhase.failed, before);
          return;
        }
        final pass = TranslationJobController(
          dao: dao,
          workId: workId,
          units: units,
          lang: step.lang,
          translate: translator.translate,
          inputOf: previous == null ? null : inputOf,
        );
        final offset = before;
        pass.addListener(() =>
            _set(TranslationJobPhase.running, offset + pass.state.doneUnits));
        _pass = pass;
        var broken = false;
        try {
          await pass.start();
        } on MarianModelInitException {
          broken = true;
        } on MarianModelMissingFilesException {
          broken = true;
        } finally {
          _pass = null;
          await translator.dispose().catchError((Object _) {});
        }
        // The real translator opens its sessions on the first sentence,
        // so a model that can't start shows up here, not in open().
        if (broken) {
          await dao.setTranslationRunLang(workId, null);
          _set(TranslationJobPhase.failed, _state.doneUnits);
          return;
        }
      }
      if (_cancelled) {
        if (!_keepMarker) await dao.setTranslationRunLang(workId, null);
        _set(TranslationJobPhase.cancelled, _state.doneUnits);
        return;
      }
      before += units.length;
      _set(TranslationJobPhase.running, before);
    }
    await dao.setTranslationRunLang(workId, null);
    _set(TranslationJobPhase.done, before);
  }
}
