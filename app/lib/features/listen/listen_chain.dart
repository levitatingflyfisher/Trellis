/// One tap (1.6.0, owner: "I'd like the ability to just have a default
/// where I click play on it and then I listen to it in my learning
/// language"). Until now that was four separate presses on three
/// screens: download, transcribe, translate, read aloud.
///
/// [ListenChain] runs them as one job for one episode and one language:
/// a transcript, its translation, the translation spoken, and the result
/// saved as an episode ([storeSpokenEpisode]). Every stage is skipped
/// when its result is already on the device, so a run that was cut off
/// picks up at the first thing still missing, and an episode already
/// made is simply played.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:loom_core/loom_core.dart' as core;

import '../../db/database.dart';
import '../reader/speech/speech_engine.dart';
import '../reader/speech/spoken_text.dart';
import '../reader/translation/language_names.dart';
import '../reader/translation/sentence_units.dart';
import '../transcribe/foreground_gate.dart';
import 'spoken_episode.dart';

enum ListenStage { transcribing, translating, speaking, ready, failed }

class ListenState {
  final ListenStage stage;
  final String lang;
  final int done;
  final int total;

  /// Why it stopped, as a sentence, when [stage] is failed.
  final String? message;

  /// The episode to play, when [stage] is ready.
  final int? spokenWorkId;

  const ListenState(this.stage,
      {required this.lang,
      this.done = 0,
      this.total = 0,
      this.message,
      this.spokenWorkId});

  bool get running =>
      stage != ListenStage.ready && stage != ListenStage.failed;

  /// The fraction done of the stage under way, or null when unknown.
  double? get fraction => running && total > 0 ? done / total : null;

  /// What the page says while this is the state.
  String get line {
    final language = languageDisplayName(lang);
    final count = total > 0 ? ': $done of $total sentences' : '…';
    return switch (stage) {
      ListenStage.transcribing => 'Transcribing the episode…',
      ListenStage.translating => 'Translating into $language$count',
      ListenStage.speaking => 'Making the $language audio$count',
      ListenStage.ready => 'Ready in $language',
      ListenStage.failed => message ?? 'That didn’t work.',
    };
  }
}

/// A voice whose speech can be saved: its name for the episode's page,
/// and the call that says one sentence.
typedef SavedVoice = ({
  String name,
  Future<SynthResult> Function(String text) say,
});

class _Cancelled implements Exception {
  const _Cancelled();
}

class ListenChain extends ChangeNotifier {
  ListenChain({
    required this.db,
    required this.transcribe,
    required this.translate,
    required this.voiceFor,
    required this.audioFileFor,
    required this.tempDir,
    this.encode,
    this.foreground,
  });

  final AppDatabase db;

  /// Makes [work]'s transcript and returns when the attempt is over,
  /// whether or not it worked: the chain looks for the transcript itself.
  final Future<void> Function(Work work, Episode episode) transcribe;

  /// Translates [work]'s transcript from [source] into [target], fetching
  /// the translator if it has to. Null when done; else why not, as a
  /// sentence fit to show.
  final Future<String?> Function(Work work, String source, String target,
      void Function(int done, int total) progress) translate;

  /// The voice that can be saved to a file for [lang]; null when there
  /// is none on this device.
  final Future<SavedVoice?> Function(String lang) voiceFor;

  final File Function(int workId, String url) audioFileFor;
  final Directory tempDir;

  /// Packs the finished WAV into a smaller file and returns it, or null
  /// to keep the WAV (no encoder here, or it failed).
  final Future<File?> Function(File wav, {required String title})? encode;

  /// Keeps the app alive behind a dark screen for the whole job: an
  /// hour's episode is many minutes of work, and Android freezes an app
  /// left alone that long.
  final JobForegroundGate? foreground;

  final Map<int, ListenState> _states = {};
  final Map<int, Future<int?>> _running = {};
  final Set<int> _cancelled = {};

  ListenState? stateOf(int workId) => _states[workId];

  void _set(int workId, ListenState? s) {
    if (s == null) {
      _states.remove(workId);
    } else {
      _states[workId] = s;
    }
    notifyListeners();
  }

  /// The spoken episode of [workId] in [lang] when it is made AND its
  /// audio is still on the device; null otherwise. The file is the
  /// episode (its address can never be fetched), so one whose file was
  /// deleted counts as not made, and [start] makes it again in place
  /// from the translation that is still stored.
  Future<int?> madeEpisodeOf(int workId, String lang) async {
    final id = await spokenEpisodeOf(db, workId, lang);
    if (id == null) return null;
    final url = (await db.feedsDao.episodeOf(id))?.enclosureUrl;
    return url != null && audioFileFor(id, url).existsSync() ? id : null;
  }

  /// Stops [workId]'s run at the next sentence. What earlier stages made
  /// is kept.
  void cancel(int workId) {
    if (_running.containsKey(workId)) _cancelled.add(workId);
  }

  /// Runs what is still missing for [work] in [lang] and returns the
  /// spoken episode's id, or null when it failed (see [stateOf]) or was
  /// cancelled. A call while one is under way for the same work joins it.
  Future<int?> start(Work work, String lang) =>
      _running[work.id] ??= _run(work, lang).whenComplete(() {
        _running.remove(work.id);
        _cancelled.remove(work.id);
      });

  Future<int?> _run(Work work, String lang) async {
    void check() {
      if (_cancelled.contains(work.id)) throw const _Cancelled();
    }

    ListenState fail(String message) =>
        ListenState(ListenStage.failed, lang: lang, message: message);

    var held = false;
    // A stage's progress, on the page and in the job's notification.
    void beat(ListenState s) {
      _set(work.id, s);
      if (held) unawaited(foreground?.jobProgress(work.title, s.line));
    }

    try {
      final made = await madeEpisodeOf(work.id, lang);
      if (made != null) {
        _set(work.id,
            ListenState(ListenStage.ready, lang: lang, spokenWorkId: made));
        return made;
      }
      final episode = await db.feedsDao.episodeOf(work.id);
      if (episode == null || episode.enclosureUrl == null) {
        _set(work.id, fail('Only an episode with audio can be listened to '
            'in another language.'));
        return null;
      }

      // Held from the tap, while the app is still in front, to the end.
      // Android refuses to start this from behind a dark screen, and the
      // transcription lets go of its own hold when it finishes, so taking
      // it only then would leave translating and speaking unprotected
      // (seen on the emulator: a 50 minute episode lost the hold at
      // minute 21). The service is shared and counted, so this holds it
      // across every stage.
      await foreground?.jobStarted(
          work.title, 'Preparing ${languageDisplayName(lang)}…');
      held = true;

      // 1. The transcript.
      if ((await db.spineDao.alignmentsOf(work.id)).isEmpty) {
        _set(work.id, ListenState(ListenStage.transcribing, lang: lang));
        await transcribe(work, episode);
        check();
        if ((await db.spineDao.alignmentsOf(work.id)).isEmpty) {
          _set(work.id, fail('The transcript wasn’t made, so there is '
              'nothing to translate. Jobs says why.'));
          return null;
        }
      }
      final fresh = (await db.spineDao.workById(work.id)) ?? work;
      final source = _base(fresh.lang) ?? 'en';
      if (source == _base(lang)) {
        _set(work.id, fail('This episode is already in '
            '${languageDisplayName(lang)}.'));
        return null;
      }

      // 2. The translation.
      final units = sentenceUnitsOf(await _segments(work.id));
      var stored = await db.spineDao.translationSentencesOf(work.id, lang: lang);
      if (units.any((u) => !stored.containsKey((u.segIdx, u.sentenceIdx)))) {
        beat(ListenState(ListenStage.translating,
            lang: lang, total: units.length));
        final why = await translate(fresh, source, lang, (done, total) {
          beat(ListenState(ListenStage.translating,
              lang: lang, done: done, total: total));
        });
        check();
        if (why != null) {
          _set(work.id, fail(why));
          return null;
        }
        stored = await db.spineDao.translationSentencesOf(work.id, lang: lang);
      }
      final sentences = <({int seg, String text})>[
        for (final u in units)
          if (stored[(u.segIdx, u.sentenceIdx)] case final t?)
            if (spokenText(t.body).isNotEmpty)
              (seg: u.segIdx, text: spokenText(t.body)),
      ];
      if (sentences.isEmpty) {
        _set(work.id, fail('Nothing came out of the translation, so there '
            'is nothing to say.'));
        return null;
      }

      // 3. The voice, and the file.
      final voice = await voiceFor(lang);
      if (voice == null) {
        _set(work.id, fail('There is no voice on this device whose '
            '${languageDisplayName(lang)} can be saved as audio. The '
            'translation is kept: open the episode and use Read aloud.'));
        return null;
      }
      beat(ListenState(ListenStage.speaking,
          lang: lang, total: sentences.length));
      final wav = File('${tempDir.path}/${work.id}-$lang.wav');
      final render = await renderSpoken(
          sentences: sentences,
          synth: voice.say,
          wav: wav,
          cancelled: () => _cancelled.contains(work.id),
          onProgress: (done, total) => beat(ListenState(
              ListenStage.speaking, lang: lang, done: done, total: total)));
      File audio = wav;
      final packed = await encode?.call(wav,
          title: '${fresh.title} (${languageDisplayName(lang)})');
      if (packed != null) {
        audio = packed;
        if (wav.existsSync()) wav.deleteSync();
      }
      final id = await storeSpokenEpisode(
          db: db,
          original: fresh,
          lang: lang,
          voice: voice.name,
          render: render,
          audio: audio,
          audioFileFor: audioFileFor);
      _set(work.id,
          ListenState(ListenStage.ready, lang: lang, spokenWorkId: id));
      return id;
    } on _Cancelled {
      _set(work.id, null);
      return null;
    } on SpokenCancelled {
      _set(work.id, null);
      return null;
    } catch (e) {
      _set(work.id, fail('That didn’t work, and nothing was changed. '
          'Try again.'));
      return null;
    } finally {
      if (held) await foreground?.jobFinished();
    }
  }

  Future<List<core.Segment>> _segments(int workId) async {
    final kinds = {for (final k in core.SegmentKind.values) k.name: k};
    return [
      for (final r in await db.spineDao.segmentsOf(workId))
        core.Segment(
            idx: r.idx,
            kind: kinds[r.kind] ?? core.SegmentKind.prose,
            text: r.body),
    ];
  }
}

String? _base(String? lang) {
  final b = lang?.trim().toLowerCase().split(RegExp('[-_]')).first;
  return b == null || b.isEmpty ? null : b;
}
