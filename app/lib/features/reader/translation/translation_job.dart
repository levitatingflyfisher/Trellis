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

  TranslationJobController({
    required this.dao,
    required this.workId,
    required this.units,
    required this.translate,
    this.lang = 'es',
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
  Future<void> start() async {
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
              body: body);
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
}
