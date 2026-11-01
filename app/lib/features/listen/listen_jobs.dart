/// The one tap, wherever it is pressed (1.6.x): an episode's row in any
/// list, and the episode's page. One of these lives for the whole app, so
/// what is being made, what waits and what is ready are the same answer
/// on every screen, and a row that scrolls away or a list that is left
/// loses nothing.
///
/// It owns the learning language, the line of episodes waiting to be
/// made (one is made at a time: each is many minutes of the phone's whole
/// effort), and the rule for playing a finished one.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../models/consent.dart';
import '../player/player_controller.dart';
import '../reader/translation/language_names.dart';
import 'listen_chain.dart';
import 'listen_languages.dart';
import 'make_ahead_jobs.dart';

/// The device setting: the language the listener is learning.
const learningLanguageKey = 'learning_language';

/// The device setting: the episodes asked for and not yet finished, in
/// their order in the line, so a job outlives the app being killed.
const listenLineKey = 'listen_line';

/// What one episode's button is, right now.
class ListenOffer {
  /// The learning language, or the language being made while a job for
  /// this episode runs or waits. Null when none is chosen yet: the first
  /// tap asks.
  final String? lang;

  /// The languages this episode can be made in, as bare tags.
  final List<String> languages;

  /// It is being made now.
  final bool making;

  /// It is in line behind another episode.
  final bool waiting;

  /// It is made, and its audio is on the device.
  final bool ready;

  final ListenState? _state;

  const ListenOffer._({
    required this.lang,
    required this.languages,
    this.making = false,
    this.waiting = false,
    this.ready = false,
    ListenState? state,
  }) : _state = state;

  bool get busy => making || waiting;

  /// The last try stopped with a reason.
  bool get failed => !busy && _state?.stage == ListenStage.failed;

  /// How far the stage under way is, or null when that is not known.
  double? get fraction => making ? _state?.fraction : null;

  String get _language => languageDisplayName(lang!);

  /// What the button is, said whole: its tooltip and what a screen
  /// reader hears.
  String get label {
    if (waiting) return 'Waiting to be made in $_language';
    if (making) {
      final stage = switch (_state?.stage) {
        ListenStage.transcribing => 'transcribing',
        ListenStage.translating => 'translating',
        ListenStage.speaking => 'making the audio',
        _ => 'getting ready',
      };
      final f = fraction;
      return 'Making it in $_language: $stage'
          '${f == null ? '' : ', ${(f * 100).round()}%'}';
    }
    if (lang == null) return 'Listen in another language';
    return ready ? 'Play in $_language' : 'Listen in $_language';
  }

  /// The sentence under the choices on the episode's page.
  String get line {
    if (waiting) {
      return 'Waiting its turn: another episode is being made first.';
    }
    if (making) return _state?.line ?? 'Preparing $_language…';
    if (failed) return _state!.line;
    if (lang == null) {
      return 'Transcribes, translates and speaks the episode, then keeps '
          'the audio.';
    }
    if (ready) return '$_language is ready. The voice is machine made.';
    return 'The first time, the $_language is made on this device: the '
        'episode is transcribed, translated and spoken, and the audio is '
        'kept.';
  }
}

typedef _Job = ({
  Work work,
  String lang,
  ScaffoldMessengerState? messenger,
  bool held,

  /// Brought back after a restart, so nobody has just asked for it.
  bool restored,

  /// Made ahead: nobody asked for this one. It runs only when the line
  /// is otherwise empty, and it never plays.
  bool ahead,
});

typedef _Asked = ({int workId, String lang});

bool _appInFront() {
  final state = WidgetsBinding.instance.lifecycleState;
  return state == null || state == AppLifecycleState.resumed;
}

class ListenJobs extends ChangeNotifier {
  ListenJobs({
    required this.db,
    required this.chain,
    required this.languagesFor,
    required this.downloadsFor,
    this.player,
    bool Function()? inFront,
    this.makeAhead,
    this.sortedFor,
    this.sortedForAny,
    this.askVoices,
    this.openVoiceSettings,
    Listenable? voices,
  })  : _inFront = inFront ?? _appInFront,
        _voices = voices {
    chain.addListener(notifyListeners);
    // A late answer from the phone about its voices changes what can be
    // made: an engine binding after a cold start can take longer than the
    // first wait, and without this the rows stayed empty until the app
    // went to the background and back.
    voices?.addListener(_voicesChanged);
    ready = _load();
  }

  final AppDatabase db;
  final ListenChain chain;

  /// The languages an episode in [workLang] (or its show's [feedLang])
  /// can be made in on this device.
  final List<String> Function(
      {required String? workLang, required String? feedLang}) languagesFor;

  /// What making [work] in [lang] would download, for the one consent
  /// dialog (ADR-0003 law 6).
  final Future<List<DownloadItem>> Function(
      Work work, Episode episode, String lang) downloadsFor;

  /// Every language an episode could be made in, sorted into offered and
  /// missing with the reason, for the language dialog's note. Null where
  /// there is nothing to say.
  final ListenLanguages Function(
      {required String? workLang, required String? feedLang})? sortedFor;

  /// Every language some episode could be made in, sorted the same way:
  /// the learning-language setting asks with no episode in view.
  final ListenLanguages Function()? sortedForAny;

  /// Asks the phone again which voices it has (a voice is installed in
  /// Android's settings, outside the app).
  final Future<void> Function()? askVoices;

  /// Opens Android's text-to-speech settings; false where there are none.
  final Future<bool> Function()? openVoiceSettings;

  final PlayerController? player;
  final bool Function() _inFront;

  /// Null where nothing can be made ahead.
  final MakeAhead? makeAhead;

  /// Completes when the learning language has been read. Until then
  /// nothing is offered, so a button never appears and then goes.
  late final Future<void> ready;

  bool _loaded = false;
  String? _language;

  /// Made episodes in the learning language: the original's work id to
  /// the spoken one's.
  Map<int, int> _made = {};

  final _waiting = <_Job>[];
  _Job? _current;

  /// Read from the record at start-up and not back in the line yet: the
  /// jobs the app restores come first (see [resumeLine]).
  final _pending = <_Asked>[];
  bool _lineResumed = false;

  /// The job being made and told to stop. It stays [_current] until it
  /// has wound down, but a kill in that time must not bring it back.
  int? _stopping;

  /// The made-ahead job told to give way (a tap, or the conditions gone).
  /// It stays waiting in make ahead's own record.
  int? _yielding;

  /// A made-ahead job is being looked for, so a second look must not start.
  bool _claiming = false;
  bool _lookAgain = false;
  Completer<void>? _ended;
  Future<void> _writes = Future.value();
  final _languages = <String, List<String>>{};

  /// The learning language; null until one is chosen.
  String? get language => _language;

  /// Completes once every change to the record so far is written.
  Future<void> get saved => _writes;

  /// Writes down what is asked for, each time the line changes. In a queue
  /// and read at its turn, so the last write is always the latest line.
  void _writeLine() {
    _writes = _writes.then((_) async {
      final line = [
        // A made-ahead job has its own record: this line restarts at launch
        // whatever the network and the battery are doing, as a tap does.
        if (_current case final job?
            when job.work.id != _stopping && !job.ahead)
          (workId: job.work.id, lang: job.lang),
        for (final job in _waiting) (workId: job.work.id, lang: job.lang),
        ..._pending,
      ];
      try {
        if (line.isEmpty) {
          await db.deviceSettingsDao.clear(listenLineKey);
        } else {
          await db.deviceSettingsDao.write(
              listenLineKey,
              jsonEncode([
                for (final a in line) {'workId': a.workId, 'lang': a.lang},
              ]));
        }
      } catch (_) {
        // The database went away under it (the app is closing): the record
        // stays as it was, which is the job to pick up next time.
      }
    });
  }

  /// A value of the wrong shape is set aside and the line starts empty: a
  /// bad record must never stop the app from opening.
  Future<List<_Asked>> _readLine() async {
    final raw = await db.deviceSettingsDao.read(listenLineKey);
    if (raw == null) return [];
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      decoded = null;
    }
    if (decoded is! List) {
      await db.deviceSettingsDao.write('$listenLineKey-unreadable', raw);
      await db.deviceSettingsDao.clear(listenLineKey);
      return [];
    }
    return [
      for (final m in decoded)
        if (m case {'workId': final int workId, 'lang': final String lang})
          (workId: workId, lang: lang),
    ];
  }

  /// Puts back in line what was asked for before the app was killed, once
  /// per run of the app. Call it after the other jobs are restored: the
  /// transcription resumes by itself, and the chain joins that run rather
  /// than starting a second one.
  ///
  /// This resumes only what a person's tap started (ADR-0003), and that
  /// tap agreed to its downloads. Like the transcriptions it runs at
  /// launch, while the app is in front, so Android lets it take its hold.
  Future<void> resumeLine() async {
    if (_lineResumed) return;
    _lineResumed = true;
    await ready;
    if (_pending.isEmpty) {
      unawaited(_next());
      return;
    }
    final Map<int, Work?> works;
    try {
      works = {
        for (final a in [..._pending])
          a.workId: await db.spineDao.workById(a.workId),
      };
    } catch (_) {
      return;
    }
    // Each one that will wait takes its hold now, as a tap would: when its
    // turn comes the screen may be dark, where Android refuses one.
    final holds = <int>{};
    var ahead = _current != null;
    for (final a in [..._pending]) {
      final work = works[a.workId];
      if (work == null) continue;
      if (ahead) {
        try {
          await chain.foreground?.jobStarted(work.title,
              'Waiting to be made in ${languageDisplayName(a.lang)}');
          holds.add(a.workId);
        } catch (_) {
          // Refused: it still waits, and runs if the app is awake then.
        }
      }
      ahead = true;
    }
    // Read again: Stop may have taken one out during the waits above.
    for (final a in [..._pending]) {
      final work = works[a.workId];
      if (work == null || _queued(a.workId)) continue;
      _waiting.add((
        work: work,
        lang: a.lang,
        messenger: null,
        held: holds.remove(a.workId),
        restored: true,
        ahead: false,
      ));
    }
    _pending.clear();
    for (final _ in holds) {
      await _letGo();
    }
    _writeLine();
    notifyListeners();
    unawaited(_next());
  }

  /// Before a backup restore: ends the line and forgets the record, and
  /// returns when nothing is being made. Device settings are not part of a
  /// backup, so the record's ids would name other episodes afterwards.
  Future<void> stopAll() async {
    _pending.clear();
    makeAhead?.clearAll();
    final waiting = [..._waiting];
    _waiting.clear();
    for (final job in waiting) {
      if (job.held) await _letGo();
    }
    if (_current case final job?) {
      _stopping = job.work.id;
      chain.cancel(job.work.id);
      await _ended?.future;
    }
    _writeLine();
    notifyListeners();
    await saved;
  }

  Future<void> _load() async {
    await _askVoices();
    try {
      final stored = await db.deviceSettingsDao.read(learningLanguageKey);
      _language = stored == null || stored.isEmpty ? null : stored;
      await _readMade();
      _pending.addAll(await _readLine());
      await makeAhead?.load();
    } catch (_) {
      // The database went away under it (the app is closing): nothing is
      // offered, which is the safe answer.
      return;
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _readMade() async {
    final lang = _language;
    _made = lang == null ? {} : await chain.madeEpisodesIn(lang);
  }

  /// Looks again at which episodes are made: a screen calls this when it
  /// reloads, since made audio can be deleted from the storage page.
  Future<void> refresh() async {
    if (!_loaded) return;
    final before = _made;
    final aheadBytes = makeAhead?.madeBytes;
    try {
      await _readMade();
      await makeAhead?.refreshFacts(playingId: player?.current?.id);
    } catch (_) {
      return;
    }
    if (aheadBytes != makeAhead?.madeBytes) {
      notifyListeners();
    } else if (before.length != _made.length ||
        before.entries.any((e) => _made[e.key] != e.value)) {
      notifyListeners();
    }
  }

  Future<void> _askVoices() async {
    try {
      await askVoices?.call();
    } catch (_) {
      // No answer from the phone: its voices stay as last heard.
    }
  }

  final Listenable? _voices;

  void _voicesChanged() {
    _languages.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _voices?.removeListener(_voicesChanged);
    super.dispose();
  }

  /// Asks the phone again which voices it has, and offers again by what
  /// it says: a screen calls this when the app comes back to the front.
  Future<void> refreshVoices() async {
    if (askVoices == null) return;
    await _askVoices();
    _languages.clear();
    notifyListeners();
  }

  List<String> _languagesOf(String? workLang, String? feedLang) =>
      // Every row of a list asks. What can be made changes only when the
      // phone's voices do, and [refreshVoices] forgets these then.
      _languages['$workLang $feedLang'] ??=
          languagesFor(workLang: workLang, feedLang: feedLang);

  @visibleForTesting
  List<String> languagesOfForTest(
          {required String? workLang, required String? feedLang}) =>
      _languagesOf(workLang, feedLang);

  /// The button for [work], or null when there is none: not an episode
  /// with audio, itself a spoken translation, or one that cannot be made
  /// in the learning language (no translator from its language, no voice
  /// that can be saved, or it is in that language already).
  ListenOffer? offerFor(Work work, Episode? episode, {String? feedLang}) {
    if (!_loaded ||
        episode == null ||
        episode.enclosureUrl == null ||
        work.kind == 'audiobook' ||
        episode.guid.startsWith('spoken:')) {
      return null;
    }
    final id = work.id;
    final languages = _languagesOf(work.lang, feedLang);
    final state = chain.stateOf(id);
    // A job under way is shown whatever the learning language is now.
    if (_current case final job? when job.work.id == id) {
      return ListenOffer._(
          lang: job.lang,
          languages: languages,
          making: true,
          state: state != null && state.running ? state : null);
    }
    for (final job in _waiting) {
      if (job.work.id == id) {
        return ListenOffer._(
            lang: job.lang, languages: languages, waiting: true);
      }
    }
    for (final asked in _pending) {
      if (asked.workId == id) {
        return ListenOffer._(
            lang: asked.lang, languages: languages, waiting: true);
      }
    }
    if (languages.isEmpty) return null;
    final lang = _language;
    if (lang == null) return ListenOffer._(lang: null, languages: languages);
    if (!languages.contains(lang)) return null;
    return ListenOffer._(
        lang: lang,
        languages: languages,
        ready: _made.containsKey(id),
        state: state?.lang == lang ? state : null);
  }

  /// The learning-language setting (board-0128): the same question,
  /// asked with no episode in view, over every language some episode
  /// could be made in.
  Future<String?> chooseLearningLanguage(BuildContext context) =>
      pickLanguage(context, sortedForAny?.call().offered ?? const [],
          anyEpisode: true);

  /// Asks which language is being learned, among [languages], and keeps
  /// the answer. Null when the question was dismissed. [anyEpisode] asks
  /// for no one episode: the list and its note cover every language some
  /// episode could be made in.
  Future<String?> pickLanguage(BuildContext context, List<String> languages,
      {({String? workLang, String? feedLang})? of,
      bool anyEpisode = false}) async {
    final picked = await showDialog<String>(
      context: context,
      // Rebuilt when the phone's voices are asked again: back from
      // Android's settings with a new voice, it is listed at once.
      builder: (context) => ListenableBuilder(
        listenable: this,
        builder: (context, _) {
          final ep = of;
          final sorted = anyEpisode
              ? sortedForAny?.call()
              : ep == null
                  ? null
                  : sortedFor?.call(
                      workLang: ep.workLang, feedLang: ep.feedLang);
          final offered = anyEpisode
              ? sorted?.offered ?? languages
              : ep == null
                  ? languages
                  : _languagesOf(ep.workLang, ep.feedLang);
          final note = sorted == null
              ? null
              : listenMissingNote(sorted,
                  source: anyEpisode
                      ? null
                      : listenSourceLanguage(
                          workLang: ep!.workLang, feedLang: ep.feedLang));
          final settings = openVoiceSettings;
          final chosen = _language;
          return SimpleDialog(
            key: const Key('learning-language-dialog'),
            title: const Text('Which language are you learning?'),
            children: [
              for (final l in offered)
                SimpleDialogOption(
                  key: Key('learning-language-$l'),
                  onPressed: () => Navigator.pop(context, l),
                  child: Row(
                    children: [
                      Expanded(child: Text(languageDisplayName(l))),
                      if (l == chosen)
                        const Icon(Icons.check,
                            semanticLabel: 'Chosen now'),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                child: Text(anyEpisode
                    ? 'These are the languages Trellis can make episodes in '
                        'and keep as audio, from English or from another '
                        'language it translates. Other languages can be '
                        'translated and read aloud from an episode’s Read '
                        'page.'
                    : 'These are the languages Trellis can make this '
                        'episode in and keep as audio. Other languages can '
                        'be translated and read aloud from the episode’s '
                        'Read page.'),
              ),
              if (note != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                  child: Text(note,
                      key: const Key('learning-language-missing')),
                ),
              if (settings != null && sorted != null && sorted.noVoice.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      key: const Key('learning-language-voice-settings'),
                      onPressed: () async {
                        if (!await settings() && context.mounted) {
                          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                              const SnackBar(
                                  persist: false,
                                  content: Text('This phone’s settings '
                                      'wouldn’t open here. Look for '
                                      'Text-to-speech output in Android’s '
                                      'Settings.')));
                        }
                      },
                      child: const Text('Open text-to-speech settings'),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
    if (picked == null) return null;
    await db.deviceSettingsDao.write(learningLanguageKey, picked);
    _language = picked;
    await _readMade();
    notifyListeners();
    return picked;
  }

  /// The one tap. Plays the episode in the learning language when it is
  /// made; otherwise asks the language if none is chosen, asks once for
  /// anything it would download, and makes it, without leaving the screen
  /// the tap was on. On an episode being made or waiting, offers Stop.
  Future<void> tap(BuildContext context, Work work, Episode episode,
      {String? feedLang}) async {
    final offer = offerFor(work, episode, feedLang: feedLang);
    if (offer == null) return;
    if (offer.busy) return _offerStop(context, work, episode, feedLang);
    final lang = offer.lang ??
        await pickLanguage(context, offer.languages,
            of: (workLang: work.lang, feedLang: feedLang));
    if (lang == null || !context.mounted) return;
    await _makeOrPlay(context, work, episode, lang);
  }

  /// The one tap in a named language, which need not be the learning
  /// language (board-0130): a translation read with no audio offers to
  /// make its own language. Plays it when it is made; nothing when
  /// [lang] cannot be made for this episode.
  Future<void> makeIn(
      BuildContext context, Work work, Episode episode, String lang,
      {String? feedLang}) async {
    final offer = offerFor(work, episode, feedLang: feedLang);
    if (offer == null || !offer.languages.contains(lang)) return;
    if (offer.busy) return _offerStop(context, work, episode, feedLang);
    await _makeOrPlay(context, work, episode, lang);
  }

  Future<void> _makeOrPlay(
      BuildContext context, Work work, Episode episode, String lang) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final made = await chain.madeEpisodeOf(work.id, lang);
    if (made != null) {
      await _play(made, messenger, asked: true);
      return;
    }
    if (lang == _language && _made.remove(work.id) != null) {
      notifyListeners();
    }
    final items = await downloadsFor(work, episode, lang);
    if (items.isNotEmpty) {
      if (!context.mounted) return;
      if (!await confirmDownload(context, items: items)) return;
    }
    await _enqueue(work, lang, messenger);
  }

  /// Asks for [work] as a tap would, minus the screen; tests need no
  /// widget to see the line.
  @visibleForTesting
  Future<void> ask(Work work, String lang) => _enqueue(work, lang, null);

  bool _queued(int workId) =>
      _current?.work.id == workId || _waiting.any((j) => j.work.id == workId);

  Future<void> _enqueue(
      Work work, String lang, ScaffoldMessengerState? messenger) async {
    // Two quick taps on one row are one wish.
    if (_queued(work.id)) return;
    final ahead = _current;
    var held = false;
    if (ahead != null) {
      // One that waits holds the app awake from its own tap, while the
      // app is in front. The chain takes its hold only when it starts,
      // and by then the screen may be dark, where Android refuses.
      try {
        await chain.foreground?.jobStarted(
            work.title, 'Waiting to be made in ${languageDisplayName(lang)}');
        held = true;
      } catch (_) {
        // Refused: it still waits, and runs if the app is awake then.
      }
      if (_queued(work.id)) {
        if (held) await _letGo();
        return;
      }
    }
    _waiting.add((
      work: work,
      lang: lang,
      messenger: messenger,
      held: held,
      restored: false,
      ahead: false,
    ));
    makeAhead?.takeOver(work.id);
    _writeLine();
    notifyListeners();
    if (ahead != null && ahead.ahead) {
      // Nobody asked for that one and somebody asked for this one.
      _giveWay(ahead.work.id);
    } else if (ahead != null) {
      _say(messenger, 'One is already being made: “${ahead.work.title}”. '
          'This one waits its turn.');
    }
    unawaited(_next());
  }

  Future<void> _letGo() async {
    try {
      await chain.foreground?.jobFinished();
    } catch (_) {
      // Nothing more to let go of.
    }
  }

  /// Starts the next job if none is under way: the next one someone
  /// asked for, else the next made-ahead one. Returns once it has begun,
  /// so whoever is finishing can let go of the service after that.
  Future<void> _next() async {
    if (_current != null) return;
    if (_claiming) {
      // Whatever changed since that look began (a switch, a new episode)
      // it may have read too early, so it looks once more.
      _lookAgain = true;
      return;
    }
    if (_waiting.isNotEmpty) {
      final job = _current = _waiting.removeAt(0);
      unawaited(_run(job));
      return;
    }
    if (makeAhead == null) return;
    _claiming = true;
    _lookAgain = false;
    _Job? claimed;
    try {
      claimed = await _claimAhead();
    } catch (_) {
      claimed = null;
    } finally {
      _claiming = false;
    }
    if (_current != null || _waiting.isNotEmpty) {
      // Someone tapped while it was being looked for: they go first.
      if (claimed != null) await _letGo();
      await _next();
      return;
    }
    if (claimed == null) {
      if (_lookAgain) await _next();
      return;
    }
    _current = claimed;
    unawaited(_run(claimed));
  }

  /// The next made-ahead episode that may start now, holding the service;
  /// null when none may. Every condition is asked here, per episode.
  Future<_Job?> _claimAhead() async {
    final ahead = makeAhead!;
    final lang = _language;
    if (!_loaded || !_lineResumed || lang == null || _pending.isNotEmpty) {
      return null;
    }
    await ahead.plan(
        lang: lang,
        here: _made.containsKey,
        canMake: (work, episode, feedLang) =>
            episode.enclosureUrl != null &&
            _languagesOf(work.lang, feedLang).contains(lang));
    final fits = await ahead.makeRoom(playingId: player?.current?.id);
    await _readMade();
    notifyListeners();
    if (!fits) return null;
    for (final entry in ahead.waiting) {
      if (!await ahead.conditionsMet()) {
        // Only this path asks: the system holds the pass until both are
        // true. Asking after a refused start would fire at once and spin.
        unawaited(ahead.askForPass?.call());
        return null;
      }
      final work = await db.spineDao.workById(entry.workId);
      final episode = await db.feedsDao.episodeOf(entry.workId);
      if (work == null || episode == null || episode.enclosureUrl == null) {
        ahead.drop(entry.workId);
        continue;
      }
      final feedLang = await db.feedsDao.languageOfWorkFeed(entry.workId);
      if (!_languagesOf(work.lang, feedLang).contains(lang)) {
        ahead.drop(entry.workId);
        continue;
      }
      final made = await chain.madeEpisodeOf(work.id, lang);
      if (made != null) {
        ahead.markMade(work.id, made, lang);
        continue;
      }
      // Never a model nobody agreed to (ADR-0003 law 6). It stays waiting:
      // the model may still turn up by the person's own hand.
      final models =
          await ahead.modelsNeeded(work, episode, lang, forShow: false);
      if (models.isNotEmpty && ahead.agreedLang(entry.feedId) != lang) continue;
      // Android refuses this behind a dark screen unless the service is
      // up already. Refused means not now: it must not run unprotected.
      if (!await _tryHold(work.title, lang)) return null;
      return (
        work: work,
        lang: lang,
        messenger: null,
        held: true,
        restored: false,
        ahead: true,
      );
    }
    return null;
  }

  Future<bool> _tryHold(String title, String lang) async {
    final gate = chain.foreground;
    if (gate == null) return true;
    try {
      return await gate.tryJobStarted(
          title, 'Preparing ${languageDisplayName(lang)}…');
    } catch (_) {
      return false;
    }
  }

  void _giveWay(int workId) {
    if (_yielding == workId) return;
    _yielding = workId;
    chain.cancel(workId);
  }

  /// Runs [job], then starts the next one and only then lets go of the
  /// service: if it stopped between the two, Android would refuse the
  /// next start behind a dark screen.
  Future<void> _run(_Job job) async {
    final ended = _ended = Completer<void>();
    notifyListeners();
    final ahead = makeAhead;
    var bridge = false;
    if (!job.held && ahead != null && ahead.anyOn) {
      bridge = await _tryHold(job.work.title, job.lang);
    }
    Timer? watch;
    if (job.ahead && ahead != null) {
      watch = Timer.periodic(ahead.watchEvery, (_) async {
        if (await ahead.conditionsMet()) return;
        if (_current?.work.id == job.work.id) _giveWay(job.work.id);
      });
    }
    int? id;
    try {
      id = await chain.start(job.work, job.lang);
    } catch (_) {
      id = null;
    }
    watch?.cancel();
    try {
      await _finished(job, id);
    } catch (_) {
      // A finished job that could not be announced must not stop the line.
    }
    _current = null;
    _stopping = null;
    _yielding = null;
    ended.complete();
    _writeLine();
    notifyListeners();
    await _next();
    if (job.held) await _letGo();
    if (bridge) await _letGo();
  }

  Future<void> _finished(_Job job, int? id) async {
    if (job.ahead) return _finishedAhead(job, id);
    if (id == null) {
      final state = chain.stateOf(job.work.id);
      if (state?.stage == ListenStage.failed) _say(job.messenger, state!.line);
      return;
    }
    if (job.lang == _language) _made = {..._made, job.work.id: id};
    // No tap since the restart: the row turns to Play, and that is all.
    if (job.restored) return;
    await _play(id, job.messenger, asked: false);
  }

  /// A made-ahead job's end. It says nothing and plays nothing: the row
  /// turning to Play is all that happens.
  Future<void> _finishedAhead(_Job job, int? id) async {
    final ahead = makeAhead!;
    final workId = job.work.id;
    if (id != null) {
      ahead.markMade(workId, id, job.lang);
      if (job.lang == _language) _made = {..._made, workId: id};
      await ahead.makeRoom(playingId: player?.current?.id);
      await _readMade();
      return;
    }
    if (_yielding == workId) return;
    if (_stopping == workId) {
      ahead.drop(workId);
      return;
    }
    // Wi-Fi going often shows as a stage failing. That is not the
    // episode's fault, so it waits like any other interruption.
    if (await ahead.conditionsMet()) ahead.noteFailure(workId);
  }

  /// Runs a pass: picks what is new and starts the next made-ahead job if
  /// everything allows it. Safe to call at any time; it never waits for a
  /// job to finish.
  Future<void> makeAheadPass() async {
    if (makeAhead == null) return;
    await ready;
    await _next();
  }

  /// For the show's page: its switch, or null when there is none (the
  /// show cannot be made in the learning language, or at all).
  MakeAheadOffer? aheadOfferFor(Feed feed) {
    final ahead = makeAhead;
    if (ahead == null || !_loaded) return null;
    final languages = _languagesOf(null, feed.language);
    final lang = _language;
    if (languages.isEmpty || (lang != null && !languages.contains(lang))) {
      return null;
    }
    return MakeAheadOffer(
        on: ahead.isOn(feed.id), lang: lang, line: ahead.line(feedId: feed.id));
  }

  /// The plain line for the Jobs page; null when there is nothing to say.
  String? get aheadLine => makeAhead?.line();

  /// The show's switch. Switching on asks the learning language if none is
  /// chosen, and asks once for any model it would fetch; a no leaves it
  /// off, so nothing is ever fetched without that yes.
  Future<void> setMakeAhead(
      BuildContext context, Feed feed, bool on) async {
    final ahead = makeAhead;
    final offer = aheadOfferFor(feed);
    if (ahead == null || offer == null) return;
    if (!on) {
      ahead.switchOff(feed.id);
      notifyListeners();
      return;
    }
    final lang = offer.lang ??
        await pickLanguage(context, _languagesOf(null, feed.language),
            of: (workLang: null, feedLang: feed.language));
    if (lang == null || !context.mounted) return;
    Work? work;
    Episode? episode;
    for (final e in await db.feedsDao.episodesOfFeed(feed.id)) {
      if (e.episode.guid.startsWith('spoken:') ||
          e.episode.enclosureUrl == null) {
        continue;
      }
      if (work == null || e.work.id > work.id) {
        work = e.work;
        episode = e.episode;
      }
    }
    var agreed = false;
    if (work != null && episode != null) {
      final items =
          await ahead.modelsNeeded(work, episode, lang, forShow: true);
      if (items.isNotEmpty) {
        if (!context.mounted) return;
        if (!await confirmDownload(context, items: items)) return;
        agreed = true;
      }
    }
    await ahead.switchOn(feed.id, agreedLang: agreed ? lang : null);
    notifyListeners();
    unawaited(_next());
  }

  /// Plays the spoken episode [id]. [asked] is a tap on one already made,
  /// which always plays. The end of a job is not a tap: it may come half
  /// an hour later, so it plays only when the app is in front (Android
  /// refuses a start from behind) and nothing else is playing; otherwise
  /// it says the episode is ready, and the same button plays it.
  Future<void> _play(int id, ScaffoldMessengerState? messenger,
      {required bool asked}) async {
    final spoken = await db.spineDao.workById(id);
    final p = player;
    if (spoken == null || p == null) return;
    const kept = 'It is kept beside the original in this show.';
    final playingIt = p.playing && p.current?.id == id;
    if (!asked && ((p.playing && !playingIt) || !_inFront())) {
      _say(messenger, '“${spoken.title}” is ready. $kept');
      return;
    }
    // Play on the episode already playing would pause it.
    if (!playingIt) await p.playWork(spoken);
    _say(messenger, 'Playing “${spoken.title}”. $kept');
  }

  void _say(ScaffoldMessengerState? messenger, String sentence) {
    if (messenger == null || !messenger.mounted) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(persist: false, content: Text(sentence)));
  }

  /// Takes [workId] out of the line, or stops it at the next sentence
  /// when it is the one being made. What earlier stages made is kept.
  void stop(int workId) {
    final before = _pending.length;
    _pending.removeWhere((a) => a.workId == workId);
    final i = _waiting.indexWhere((j) => j.work.id == workId);
    if (_pending.length != before) {
      _writeLine();
      notifyListeners();
    } else if (i >= 0) {
      final job = _waiting.removeAt(i);
      if (job.held) unawaited(_letGo());
      _writeLine();
      notifyListeners();
    } else if (_current?.work.id == workId) {
      _stopping = workId;
      _writeLine();
      chain.cancel(workId);
    }
  }

  Future<void> _offerStop(BuildContext context, Work work, Episode episode,
      String? feedLang) async {
    final stop = await showDialog<bool>(
      context: context,
      builder: (context) => ListenableBuilder(
        listenable: this,
        builder: (context, _) {
          final offer = offerFor(work, episode, feedLang: feedLang);
          final busy = offer != null && offer.busy;
          return AlertDialog(
            key: const Key('listen-stop-dialog'),
            title: Text(work.title, maxLines: 2, overflow: TextOverflow.ellipsis),
            content: Text(offer?.line ?? 'It has stopped.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(busy ? 'Keep going' : 'Close'),
              ),
              if (busy)
                TextButton(
                  key: const Key('listen-stop'),
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Stop'),
                ),
            ],
          );
        },
      ),
    );
    if (stop ?? false) this.stop(work.id);
  }
}
