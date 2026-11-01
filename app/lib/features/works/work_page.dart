/// One page per work (1.5.4): an episode, a book, an article or a note.
/// Every row's tap opens it (`WorkDoors.open`); a row's Play still plays
/// at once and never comes here.
///
/// No mode is primary: Listen, Read and (for video) Watch sit side by
/// side at equal weight, and a mode that can't work says why instead of
/// hiding. The page opens on the mode and language last used for this
/// work, so coming back is one tap from where it was left.
///
/// An episode that can be made in the learning language shows four
/// choices as one group instead: listen or read, in the original or in
/// that language. Listening in it is the one tap, the same job as the
/// second button on the episode's row.
library;

export '../transcribe/job_cards.dart' show transcribeEstimate;

import '../listen/listen.dart';
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show TableUpdate, TableUpdateQuery;
import 'package:flutter/material.dart';
import 'package:openhearth_design/openhearth_design.dart';

import '../feeds/episode_download_coordinator.dart'
    show EpisodeDownloadState, downloadFraction, downloadingWords;
import '../transcribe/job_cards.dart';
import '../../db/database.dart' hide Alignment;
import '../episodes/episode_actions.dart';
import '../models/format.dart';
import '../reader/reader_screen.dart' show ReaderNote;
import '../reader/translation/language_names.dart';
import '../river/river_triage.dart';
import '../shared/capped_body.dart';
import '../storage/work_storage.dart';
import 'episode_versions.dart';
import 'notes_view.dart';
import 'remove_undo.dart';
import 'work_menu.dart';
import 'work_open.dart';
import 'work_row.dart';

enum WorkMode { listen, read, watch }

/// The mode this work was last used in: the newest of the mode the page
/// last opened it in ([Works.lastMode]), the reader's place (read, or
/// speak, which is listening to a text) and the player's raw place. The
/// page's own record covers the ways in that keep no place (the
/// transcript, the show notes); the places cover use that never came
/// through the page (a row's Play). With none, the kind's own mode:
/// Listen for audio, Read for a text.
WorkMode lastUsedMode({
  required bool audio,
  Work? work,
  Position? position,
  PlayerPosition? player,
}) {
  final candidates = <(int, WorkMode)>[
    if (work?.lastMode case final mode? when work?.lastModeAtMs != null)
      (
        work!.lastModeAtMs!,
        WorkMode.values.firstWhere(
          (m) => m.name == mode,
          orElse: () => audio ? WorkMode.listen : WorkMode.read,
        ),
      ),
    if (position != null)
      (
        position.updatedAtMs,
        position.lastModality == 'read' ? WorkMode.read : WorkMode.listen,
      ),
    if (player != null && player.tMs > 0) (player.updatedAtMs, WorkMode.listen),
  ];
  if (candidates.isEmpty) return audio ? WorkMode.listen : WorkMode.read;
  // The first listed wins a tie: the page's record is the deliberate one.
  var best = candidates.first;
  for (final c in candidates.skip(1)) {
    if (c.$1 > best.$1) best = c;
  }
  return best.$2;
}

/// A language the work can be read in: its original, or a translation
/// that already exists for it.
class WorkLanguage {
  /// Null for the original.
  final String? tag;

  /// Whole-segment `mt` layer (a transcribe-and-translate pass) rather
  /// than the reader's sentence-by-sentence translation.
  final bool layer;
  const WorkLanguage.original() : tag = null, layer = false;
  const WorkLanguage.translation(String this.tag, {this.layer = false});

  bool get isOriginal => tag == null;

  @override
  bool operator ==(Object other) =>
      other is WorkLanguage && other.tag == tag && other.layer == layer;

  @override
  int get hashCode => Object.hash(tag, layer);
}

/// `en-us` and `en` both name English.
String languageNameOf(String? code) {
  if (code == null || code.trim().isEmpty) return 'Unknown';
  return languageDisplayName(_bare(code));
}

/// The language a tag names, without its region: `en-US` is `en`.
String _bare(String code) =>
    code.trim().toLowerCase().split(RegExp('[-_]')).first;

class WorkPage extends StatefulWidget {
  final WorkDoors doors;
  final WorkEntry entry;

  /// The show's name, when the opener knows it; the page looks it up
  /// otherwise.
  final String? showTitle;

  const WorkPage({
    super.key,
    required this.doors,
    required this.entry,
    this.showTitle,
  });

  @override
  State<WorkPage> createState() => _WorkPageState();
}

class _WorkPageState extends State<WorkPage> {
  late Work _work = widget.entry.work;
  late Episode? _episode = widget.entry.episode;
  Feed? _feed;
  WorkNote? _notes;
  String? _opening; // a text work's first lines, as its description
  WorkRowFacts? _facts;
  WorkMode? _mode;
  List<WorkLanguage> _translations = const [];
  WorkLanguage _language = const WorkLanguage.original();
  List<CaptureRow> _captures = const [];
  WorkStorage? _stored;

  /// An episode's original and its made versions (board-0130); null for
  /// anything that is not an episode with audio.
  EpisodeVersions? _versions;
  bool _loaded = false;

  WorkDoors get _doors => widget.doors;
  AppDatabase get _db => _doors.db;
  EpisodeActions? get _actions => _doors.actions;
  WorkEntry get _entry => (work: _work, episode: _episode);
  bool get _isAudio => !isTextWork(_work, _episode);
  bool get _isAudiobook => _work.kind == 'audiobook';
  bool get _transcribed => _facts?.transcribed ?? false;

  StreamSubscription<Set<TableUpdate>>? _transcriptWrites;

  @override
  void initState() {
    super.initState();
    _markSeen();
    _load();
    // Jobs finish while the page is open (1.5.6): a transcript landing or
    // a download completing must change what the page offers without
    // leaving and coming back.
    _transcriptWrites = _db
        .tableUpdates(TableUpdateQuery.onTable(_db.alignments))
        .listen((_) {
      if (!_transcribed) _load();
    });
    _actions?.downloader?.addListener(_onDownloads);
    _jobs?.addListener(_onJobs);
    _wasReady = _offer?.ready ?? false;
  }

  ListenJobs? get _jobs => _actions?.listenJobs;

  /// The learning language's choices for this episode; null where there
  /// are none (a text, an audiobook, the web, or an episode that cannot
  /// be made in it), and the page is then as it always was.
  ListenOffer? get _offer => _isAudio && !_isAudiobook
      ? _jobs?.offerFor(_work, _episode, feedLang: _feed?.language)
      : null;

  bool _wasReady = false;

  /// A job that just finished wrote a transcript and a translation: the
  /// page reads again, so Read in that language is there at once.
  void _onJobs() {
    if (!mounted) return;
    final ready = _offer?.ready ?? false;
    if (ready && !_wasReady) _load();
    _wasReady = ready;
  }

  bool _onDisk(Episode? e) {
    final url = e?.enclosureUrl;
    final d = _actions?.downloader;
    return e != null && url != null && d != null && d.isDownloaded(e.workId, url);
  }

  void _onDownloads() {
    if (!mounted) return;
    if (_onDisk(_episode) != (_facts?.downloaded ?? false)) {
      _load();
    } else if (_downloading != null || _wasDownloading) {
      // How far it has got, where Listen is.
      setState(() {});
    }
    _wasDownloading = _downloading != null;
  }

  bool _wasDownloading = false;

  /// This episode's download while one is under way; null otherwise.
  EpisodeDownloadState? get _downloading {
    final s = _actions?.downloader?.stateOf(_work.id);
    return s != null && s.downloading ? s : null;
  }

  /// What Play does with this episode when it isn't downloaded, as
  /// Settings has it; null until read.
  bool? _playsDownloadFirst;

  /// The other way to play this episode, for this one play: shown on the
  /// page beside Listen, which does what Settings says.
  bool get _offersPlayChoice =>
      _isAudio &&
      !_isAudiobook &&
      _language.isOriginal &&
      _playsDownloadFirst != null &&
      _downloading == null &&
      (_episode == null ? false : _actions?.offersPlayChoice(_episode!) ?? false);

  Future<void> _playOtherWay() async {
    _remember(WorkMode.listen);
    await _doors.play(_work, downloadFirst: !_playsDownloadFirst!);
    await _load();
  }

  @override
  void dispose() {
    _transcriptWrites?.cancel();
    _actions?.downloader?.removeListener(_onDownloads);
    _jobs?.removeListener(_onJobs);
    super.dispose();
  }

  /// Opening a feed item is looking at it, so its New marker clears, the
  /// same as opening it to read always did.
  Future<void> _markSeen() async {
    final e = _episode;
    if (e == null || e.readAtMs != null) return;
    await _db.feedsDao.markRead(
      _work.id,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _load() async {
    final id = _work.id;
    final profileId = _doors.profileId;
    final work = await _db.spineDao.workById(id) ?? _work;
    final episode = await _db.feedsDao.episodeOf(id);
    final feed = episode == null
        ? null
        : await _db.feedsDao.feedById(episode.feedId);
    final notes = await _db.feedsDao.notesOf(id);
    final entry = (work: work, episode: episode);
    final state = await WorkListState.load(_db, profileId, entries: [entry]);
    final facts = WorkRowFacts.of(
      work,
      episode,
      state,
      // Disk truth, not the actions' cache: a transcription fetches the
      // audio without the downloader, so its revision never moves.
      downloaded: _onDisk(episode),
    );
    final position = await _db.spineDao.position(
      profileId: profileId,
      workId: id,
    );
    final player = await _db.feedsDao.playerPosition(
      profileId: profileId,
      workId: id,
    );
    final sentenceLangs = await _db.spineDao.translationLangsOf(id);
    final layerLangs = await _db.spineDao.layerLangsOf(id, kind: 'mt');
    final translations = [
      for (final l in sentenceLangs) WorkLanguage.translation(l),
      for (final l in layerLangs)
        if (!sentenceLangs.contains(l))
          WorkLanguage.translation(l, layer: true),
    ];
    final picked = work.readLang;
    final language = translations.firstWhere(
      (t) => t.tag == picked,
      orElse: () => const WorkLanguage.original(),
    );
    final captures = await _db.capturesDao.capturesOf(id);
    final playsDownloadFirst = await _doors.player?.playsDownloadFirst();
    final stored = await loadWorkStorage(_db,
        services: _actions?.services, onlyWorkId: id);
    final versions = episode == null ||
            episode.enclosureUrl == null ||
            work.kind == 'audiobook'
        ? null
        : await loadEpisodeVersions(_db,
            work: work,
            episode: episode,
            audioFileFor: _actions?.services?.audioFileFor);
    String? opening;
    if (notes == null && isTextWork(work, episode)) {
      opening = await _openingOf(id);
    }
    if (!mounted) return;
    setState(() {
      _work = work;
      _episode = episode;
      _feed = feed;
      _notes = notes;
      _opening = opening;
      _facts = facts;
      _mode = lastUsedMode(
        audio: !isTextWork(work, episode),
        work: work,
        position: position,
        player: player,
      );
      _translations = translations;
      _language = language;
      _captures = captures;
      _playsDownloadFirst = playsDownloadFirst;
      _stored = stored.isEmpty ? null : stored.single;
      _versions = versions;
      _loaded = true;
    });
  }

  /// A text's first few paragraphs stand in for a description: intake
  /// keeps none for a book or an article.
  Future<String?> _openingOf(int workId) async {
    final segs = await _db.spineDao.segmentsOf(workId);
    final out = StringBuffer();
    for (final s in segs) {
      if (out.length > notesFoldChars) break;
      final text = s.body.trim();
      if (text.isEmpty) continue;
      out.write('<p>${_escape(text)}</p>');
    }
    return out.isEmpty ? null : out.toString();
  }

  static String _escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  String? get _showTitle => widget.showTitle ?? _feed?.title;

  String get _originalName => languageNameOf(_work.lang ?? _feed?.language);

  // ───── modes ─────

  /// Why Listen can't run here, or null when it can.
  String? get _listenBlocked {
    if (_isAudio) {
      if (_doors.player == null) return 'Playing isn’t available here.';
      if (!_language.isOriginal && !_transcribed) {
        return 'A translation needs a transcript first.';
      }
      return null;
    }
    // A text is read aloud by the reader, which always has the system
    // voice to fall back on.
    return null;
  }

  /// Why Read can't run here, or null when it can.
  String? get _readBlocked => _readBlockedIn(_language.isOriginal);

  String? _readBlockedIn(bool original) {
    if (_isAudiobook) return 'An audiobook has no text to read.';
    if (_isAudio &&
        _transcribed &&
        !_doors.readerDoors.canOpenTranscript &&
        original) {
      return 'The transcript needs the player, which isn’t here.';
    }
    return null;
  }

  bool get _hasVideo => _facts?.video ?? false;

  /// What the page opens on next time: every way in through it says so,
  /// including the ones that keep no reading place. Not awaited: on the
  /// upgrade launch the writer can be busy with an index or notes fill,
  /// and Listen must not wait on it to start playing.
  void _remember(WorkMode mode) => unawaited(_db.spineDao
      .setLastMode(_work.id, mode.name, DateTime.now().millisecondsSinceEpoch)
      .catchError((Object _) {}));

  Future<void> _listen() async {
    _remember(WorkMode.listen);
    final work = _work;
    if (_isAudio && _language.isOriginal) {
      await _doors.play(work);
    } else {
      // A text read aloud, or a translation of a transcript spoken.
      await _doors.read(
        context,
        _entry,
        startSpeaking: true,
        speakTranslation: !_language.isOriginal && !_language.layer,
        layerLang: _language.layer ? _language.tag : null,
      );
    }
    await _load();
  }

  Future<void> _read() async {
    _remember(WorkMode.read);
    if (_isAudio && !_transcribed) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => NotesScreen(
            title: _work.title,
            html: _notes?.html,
            onTimestamp: _seekTo,
            maxTimestamp: _notesEnd,
            onOpenLink: _doors.openLink,
            transcribeLabel: _transcribeLabel,
            onTranscribe: _canTranscribe ? _transcribe : null,
          ),
        ),
      );
    } else if (_isAudio && _language.isOriginal) {
      await _doors.readFromRow(context, _entry);
    } else {
      // The reader shows the chosen translation.
      await _doors.read(
        context,
        _entry,
        layerLang: _language.layer ? _language.tag : null,
        note: _translationNote(_language.tag),
      );
    }
    await _load();
  }

  /// Read in a translation of an episode says at the top whether that
  /// language has audio (board-0130: the owner tapped Spanish and kept
  /// hearing English). With audio, it plays it; without, it offers the
  /// one tap that makes it, where this episode can be made in it.
  ReaderNote? _translationNote(String? tag) {
    final v = _versions;
    if (v == null || tag == null) return null;
    final lang = _bare(tag);
    final name = languageNameOf(lang);
    if (v.withAudio(lang) case final made?) {
      return ReaderNote(
        'This is the $name text. The $name audio is its own episode.',
        action: 'Play the $name audio',
        onAction: (_) async {
          final work = await _db.spineDao.workById(made.workId);
          if (work != null) await _doors.play(work);
        },
      );
    }
    final jobs = _jobs;
    final offer = _isOriginal
        ? jobs?.offerFor(v.original, v.originalEpisode,
            feedLang: _feed?.language)
        : null;
    final canMake = offer != null && offer.languages.contains(lang);
    return ReaderNote(
      'This is the $name text. There is no $name audio yet.',
      action: canMake ? 'Make the $name audio' : null,
      onAction: canMake
          ? (context) => jobs!.makeIn(
              context, v.original, v.originalEpisode, lang,
              feedLang: _feed?.language)
          : null,
    );
  }

  bool get _isOriginal => _versions?.original.id == _work.id;

  /// Goes to another language's episode, playing it first when asked: the
  /// page opens on what is being heard.
  Future<void> _openVersion(int workId, {required bool play}) async {
    final work = await _db.spineDao.workById(workId);
    final episode = await _db.feedsDao.episodeOf(workId);
    if (work == null || !mounted) return;
    if (play) await _doors.play(work);
    if (!mounted) return;
    await _doors.open(context, (work: work, episode: episode));
    if (mounted) await _load();
  }

  // ───── transcribe ─────

  bool get _canTranscribe =>
      _isAudio && !_isAudiobook && (_actions?.canTranscribe ?? false);

  String get _transcribeLabel =>
      'Transcribe '
      '(${transcribeEstimate(_episode?.durationMs, _doors.transcribeRate())})';

  Future<void> _transcribe() async {
    final e = _episode;
    final actions = _actions;
    if (e == null || actions == null) return;
    await actions.transcribe(context, (
      work: _work,
      episode: e,
    ), translate: false);
  }

  /// A time in the notes past the episode's end is a clock time or a
  /// verse, not a place to play from. Null when the length is unknown.
  Duration? get _notesEnd {
    final ms = _episode?.durationMs;
    return ms == null || ms <= 0 ? null : Duration(milliseconds: ms);
  }

  void _seekTo(Duration at) {
    final p = _doors.player;
    if (p == null || !_isAudio || _isAudiobook) return;
    p.playWorkAt(_work, at);
  }

  // ───── language ─────

  /// Picking a language remembers it ([Works.readLang]); picking a
  /// translation also opens Read in it, since reading it is what the tap
  /// asks for. The original just becomes the choice.
  Future<void> _pickLanguage(WorkLanguage l) async {
    await _chooseLanguage(l);
    if (!mounted) return;
    if (!l.isOriginal && _readBlocked == null) await _read();
  }

  Future<void> _chooseLanguage(WorkLanguage l) async {
    final id = _work.id;
    await _db.spineDao.setReadLang(id, l.tag);
    if (l.isOriginal) {
      await _db.spineDao.setShowTranslationLayer(id, false);
    } else if (!l.layer) {
      // The reader shows the chosen translation under each sentence.
      await _db.spineDao.setActiveTranslationLang(id, l.tag!);
    }
    if (!mounted) return;
    setState(() => _language = l);
  }

  /// Translate opens the reader's Translate sheet, which asks the source
  /// when nobody knows it and never lists it as a target. It needs text,
  /// so an episode without a transcript waits for one (1.5.6: it used to
  /// transcribe-and-translate into English, even for an English episode).
  VoidCallback? get _translate {
    if (_isAudiobook) return null;
    if (_isAudio && !_transcribed) return null;
    if (_doors.readerDoors.translation == null) return null;
    return () async {
      await _doors.read(context, _entry, openTranslatePicker: true);
      await _load();
    };
  }

  // ───── actions ─────

  bool get _isKept => _work.persistence == 'work';

  bool get _showsDownload =>
      _episode?.enclosureUrl != null &&
      (_actions?.canDownload ?? false) &&
      !(_facts?.downloaded ?? false);

  Future<void> _keep() async {
    await RiverTriage(
      _db,
    ).keep(_work.id, nowMs: DateTime.now().millisecondsSinceEpoch);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(
          content: Text('Kept. It’s in your library now.'),
          persist: false,
        ),
      );
  }

  Future<void> _menu(String choice) async {
    final actions = _actions;
    switch (choice) {
      case 'remove' || 'remove-from-library':
        _remove();
        return;
    }
    if (_deletablePart(choice) case final part?) {
      await _deletePart(part);
      return;
    }
    if (actions == null || !mounted) return;
    await actions.handleShared(context, choice, _entry, showTitle: _showTitle);
    await _load();
  }

  /// Remove: the page closes at once, and the lasting Undo stays on the
  /// screen beneath, through the same helper the Library row uses. The
  /// removal's outcome goes back to the opener, so a list can hide the
  /// work while Undo stands.
  void _remove() {
    final removal = removeWithUndo(
      ScaffoldMessenger.of(context),
      db: _db,
      work: _work,
      fromFeed: _episode != null,
      deleteAudiobookFiles: _actions?.deleteAudiobookFiles,
    );
    Navigator.of(context).pop(removal);
  }

  // ───── stored parts (1.5.8) ─────

  /// What this page offers to delete: the download, the transcript and
  /// each translation. The decoded copy is a cache the storage page
  /// clears; it isn't something a reader thinks of as this work's.
  List<StoredPart> get _deletableParts => [
        for (final p in _stored?.parts ?? const <StoredPart>[])
          if (p.kind != StoredKind.decoded) p,
      ];

  static String _partValue(StoredPart p) => switch (p.kind) {
        StoredKind.audio => 'remove-download',
        StoredKind.transcript => 'delete-transcript',
        StoredKind.translation => 'delete-translation-${p.lang}',
        StoredKind.decoded => 'delete-decoded',
      };

  StoredPart? _deletablePart(String value) {
    for (final p in _deletableParts) {
      if (_partValue(p) == value) return p;
    }
    return null;
  }

  Future<void> _deletePart(StoredPart part) async {
    final stored = _stored;
    if (stored == null) return;
    if (!await confirmDeletePart(context, stored, part,
        restorable: _actions?.services?.recentlyDeleted != null)) {
      return;
    }
    final message = await deletePart(stored, part,
        db: _db, services: _actions?.services, actions: _actions);
    // The alignments listener only reloads an untranscribed page.
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message), persist: false));
  }

  /// The values of the shared items this page shows as buttons, which its
  /// ⋮ leaves out. Mirrors [_visibleActions] and the language row.
  Set<String> get _shownAsButtons => {
    if (_episode?.enclosureUrl != null) ...{'play-next', 'play-last'},
    if (_showsDownload) 'download',
    if (_offersPlayChoice) ...{'stream-now', 'download-play'},
    if (_showsTranscribe) 'transcribe',
  };

  bool get _showsTranscribe =>
      _canTranscribe && !_transcribed && _episode?.archivedAtMs == null;

  List<PopupMenuEntry<String>> _menuItems() {
    final actions = _actions;
    final id = _work.id;
    final extras = <PopupMenuEntry<String>>[
      for (final p in _deletableParts)
        PopupMenuItem(
          key: Key('${_partValue(p)}-$id'),
          value: _partValue(p),
          child: Text(p.deleteLabel),
        ),
      if (_episode != null && _isKept)
        PopupMenuItem(
          key: Key('remove-from-library-$id'),
          value: 'remove-from-library',
          child: const Text('Remove from Library'),
        )
      else if (_episode == null)
        PopupMenuItem(
          key: Key('remove-$id'),
          value: 'remove',
          child: const Text('Remove'),
        ),
    ];
    if (actions == null) return extras;
    return workMenuItems(
      actions,
      _entry,
      extras: extras,
      transcribed: _transcribed,
      sourceLang: _work.lang ?? _feed?.language,
      shownAsButtons: _shownAsButtons,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_kindTitle),
        actions: [
          if (_loaded)
            OhBarActions(
              children: [
                OhBarOverflow<String>(
                  key: const Key('work-page-menu'),
                  itemBuilder: (_) => _menuItems(),
                  onSelected: _menu,
                ),
              ],
            ),
        ],
      ),
      body: CappedBody(
        child: !_loaded
            ? const Center(child: CircularProgressIndicator())
            // Not a lazy list: the page is short, and every part of it
            // must exist to be scrolled to at large text.
            : SingleChildScrollView(
                key: const Key('work-page'),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(context),
                    const SizedBox(height: 16),
                    // The one tap's job moves while the page is open.
                    ListenableBuilder(
                      listenable: _jobs ?? const _Still(),
                      builder: (context, _) {
                        final offer = _offer;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _modes(context, offer),
                            const SizedBox(height: 16),
                            _languages(context, offer),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    _visibleActions(context),
                    const Divider(height: 32),
                    ..._body(context),
                  ],
                ),
              ),
      ),
    );
  }

  String get _kindTitle => switch (_work.kind) {
    'episode' when _isAudio => 'Episode',
    'episode' || 'article' => 'Article',
    'book' => 'Book',
    'audiobook' => 'Audiobook',
    _ => 'Note',
  };

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final facts = _facts!;
    final e = _episode;
    final File? art = e == null ? null : _actions?.artworkFor(e);
    final scheme = theme.colorScheme;
    final glyph = Container(
      width: 88,
      height: 88,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        kindIcon(_work.kind, e),
        size: 40,
        color: scheme.onSurfaceVariant,
      ),
    );
    final picture = art == null
        ? glyph
        : ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(
              art,
              width: 88,
              height: 88,
              cacheWidth: thumbCacheWidth(context, 88),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => glyph,
            ),
          );
    // At large text on a phone the words need the width more than the
    // picture does.
    final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
    final stack = scale >= 1.6 && MediaQuery.sizeOf(context).width < 400;
    final words = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _work.title,
          key: const Key('work-page-title'),
          style: theme.textTheme.titleLarge,
        ),
        const SizedBox(height: 4),
        Text(
          workMeta(_work, e, facts, _showTitle),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: workMarkers(theme, facts, _work.id),
        ),
      ],
    );
    if (stack) return words;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        picture,
        const SizedBox(width: 16),
        Expanded(child: words),
      ],
    );
  }

  Widget _modes(BuildContext context, ListenOffer? offer) {
    final theme = Theme.of(context);
    final four = offer != null;
    // In the group of four the first column is always the original,
    // whatever translation was last read.
    final listenWhy = four
        ? (_doors.player == null ? 'Playing isn’t available here.' : null)
        : _listenBlocked;
    final readWhy = four ? _readBlockedIn(true) : _readBlocked;
    const watchWhy = 'Video plays as sound for now: Listen plays it.';
    Widget choice({
      required Key key,
      required Widget icon,
      required String label,
      String? sub,
      String? says,
      bool selected = false,
      required VoidCallback? onPressed,
    }) {
      final style = ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size.fromHeight(56)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        ),
      );
      // Built inside the button, so the small line takes the button's
      // own colour and reads on the filled one too.
      Widget child = Builder(
        builder: (context) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            icon,
            const SizedBox(height: 2),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            if (sub != null)
              Text(
                sub,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: DefaultTextStyle.of(context).style.color,
                ),
              ),
          ],
        ),
      );
      if (says != null) {
        // One sentence for the whole button, which names the language.
        child = Semantics(label: says, excludeSemantics: true, child: child);
      }
      final button = selected
          ? FilledButton(
              key: key,
              style: style,
              onPressed: onPressed,
              child: child,
            )
          // Outlined, not tonal: one filled action per screen
          // (1.5.9), and the others stay the same size, in reach.
          : OutlinedButton(
              key: key,
              style: style,
              onPressed: onPressed,
              child: child,
            );
      return Expanded(
        child: Semantics(
          key: selected ? const Key('mode-selected') : null,
          selected: selected,
          button: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: says == null
                ? button
                : Tooltip(
                    message: says,
                    excludeFromSemantics: true,
                    child: button,
                  ),
          ),
        ),
      );
    }

    Widget mode(
      WorkMode mode,
      IconData icon,
      String label,
      String? why,
      VoidCallback onPressed, {
      String? sub,
    }) => choice(
      key: Key('mode-${mode.name}'),
      icon: Icon(icon),
      label: label,
      sub: sub,
      selected: _mode == mode,
      onPressed: why == null ? onPressed : null,
    );

    final original = four ? 'Original' : null;
    final downloading = _downloading;
    final listen = downloading == null
        ? mode(
            WorkMode.listen,
            Icons.headphones_outlined,
            'Listen',
            listenWhy,
            four ? () => _inOriginal(_listen) : _listen,
            sub: original,
          )
        // A download under way shows where Play is (owner, 9 Nov).
        : choice(
            key: const Key('mode-listen'),
            icon: SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(
                value: downloadFraction(downloading),
                strokeWidth: 2.5,
              ),
            ),
            label: 'Listen',
            sub: downloadingWords(downloading),
            selected: _mode == WorkMode.listen,
            onPressed: listenWhy == null
                ? (four ? () => _inOriginal(_listen) : _listen)
                : null,
          );
    final read = mode(
      WorkMode.read,
      Icons.chrome_reader_mode_outlined,
      'Read',
      readWhy,
      four ? () => _inOriginal(_read) : _read,
      sub: original,
    );
    final watch = _hasVideo
        ? mode(WorkMode.watch, Icons.movie_outlined, 'Watch', watchWhy, () {})
        : null;

    final learning = offer == null ? null : _learning(offer);
    final reasons = [
      if (listenWhy != null) 'Listen: $listenWhy',
      if (readWhy != null) 'Read: $readWhy',
      if (learning?.readWhy case final why?)
        'Read in ${learning!.name}: $why',
      if (_hasVideo) 'Watch: $watchWhy',
      if (_isAudio && !_isAudiobook && !_transcribed && readWhy == null)
        'No transcript yet: Read opens the show notes.',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (offer == null || learning == null)
          Row(children: [listen, read, ?watch])
        else ...[
          Row(
            children: [
              listen,
              choice(
                key: const Key('listen-in-language'),
                icon: offer.making
                    ? SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                            value: offer.fraction, strokeWidth: 2.5),
                      )
                    : Icon(offer.waiting
                        ? Icons.hourglass_empty
                        : offer.ready
                            ? Icons.play_circle
                            : Icons.translate),
                label: 'Listen',
                sub: learning.sub,
                says: offer.label,
                onPressed: () => _jobs!.tap(context, _work, _episode!,
                    feedLang: _feed?.language),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              read,
              choice(
                key: const Key('read-in-language'),
                icon: const Icon(Icons.chrome_reader_mode_outlined),
                label: 'Read',
                sub: learning.sub,
                says: 'Read in ${learning.name}',
                onPressed: learning.read,
              ),
            ],
          ),
          if (watch != null) ...[
            const SizedBox(height: 8),
            Row(children: [watch]),
          ],
          _learningStatus(theme, offer),
        ],
        if (_offersPlayChoice) _playChoice(),
        for (final r in reasons)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(
              r,
              key: Key('mode-reason-${reasons.indexOf(r)}'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        // A running transcription shows here, beside Read, not only on
        // the main screen's strip.
        if (_actions?.transcriber case final t?)
          ListenableBuilder(
            listenable: t,
            builder: (context, _) =>
                t.cards.any((c) => c.workId == _work.id)
                    ? Padding(
                        key: Key('page-transcribe-progress-${_work.id}'),
                        padding: const EdgeInsets.only(top: 8),
                        child: TranscribeJobCards(
                            coordinator: t, workId: _work.id),
                      )
                    : const SizedBox.shrink(),
          ),
      ],
    );
  }

  /// Stream or download, said plainly (owner, 23 Oct): Listen does what
  /// Settings says, and this plays it the other way, this once.
  Widget _playChoice() {
    final stream = _playsDownloadFirst!;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Tooltip(
          message: stream
              ? 'Play it now over the internet, without downloading it first'
              : 'Download it to this phone, then play it',
          child: TextButton.icon(
            key: Key('page-play-other-${_work.id}'),
            style: const ButtonStyle(
              minimumSize: WidgetStatePropertyAll(Size(48, 48)),
            ),
            onPressed: _playOtherWay,
            icon: Icon(stream ? Icons.wifi : Icons.download_outlined),
            label: Text(stream ? 'Stream now' : 'Download, then play'),
          ),
        ),
      ),
    );
  }

  /// The first column of the four: the original, whatever translation
  /// was read last.
  Future<void> _inOriginal(Future<void> Function() go) async {
    if (!_language.isOriginal) {
      await _chooseLanguage(const WorkLanguage.original());
      if (!mounted) return;
    }
    await go();
  }

  /// The second column of the four: what it is called, and what Read in
  /// it does. Reading the learning language opens its translation when
  /// there is one, and otherwise the reader's Translate, which needs a
  /// transcript.
  ({String name, String sub, VoidCallback? read, String? readWhy}) _learning(
    ListenOffer offer,
  ) {
    final lang = offer.lang;
    final name = lang == null ? 'another language' : languageNameOf(lang);
    final sub = lang == null ? 'Another language' : name;
    final made = _translations.where((t) => t.tag == lang).toList()
      // The reader's own sentence-by-sentence translation first.
      ..sort((a, b) => (a.layer ? 1 : 0) - (b.layer ? 1 : 0));
    if (made.isNotEmpty) {
      return (
        name: name,
        sub: sub,
        read: () => _pickLanguage(made.first),
        readWhy: null,
      );
    }
    if (_translate case final translate?) {
      return (name: name, sub: sub, read: translate, readWhy: null);
    }
    final listenIt = lang == null ? 'Listen' : 'Listen in $name';
    return (
      name: name,
      sub: sub,
      read: null,
      readWhy: !_transcribed
          ? 'A translation needs a transcript first. $listenIt makes both.'
          : 'This device can’t translate offline. $listenIt makes the '
                'translation.',
    );
  }

  /// Under the four: what the learning language's job is doing, with Stop
  /// while it runs and Change for the language when it doesn't.
  Widget _learningStatus(ThemeData theme, ListenOffer offer) {
    final id = _work.id;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (offer.making)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: LinearProgressIndicator(
                key: const Key('listen-in-language-progress'),
                value: offer.fraction,
              ),
            ),
          Row(
            children: [
              Expanded(
                child: Text(
                  offer.line,
                  key: const Key('listen-in-language-line'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: offer.failed
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (offer.busy)
                TextButton(
                  key: const Key('listen-in-language-stop'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => _jobs!.stop(id),
                  child: const Text('Stop'),
                )
              // Even with one language offered: the list's note says why
              // the others are missing (board-0128).
              else if (offer.lang != null)
                TextButton(
                  key: const Key('learning-language-change'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => _jobs!.pickLanguage(
                      context, offer.languages,
                      of: (workLang: _work.lang, feedLang: _feed?.language)),
                  child: const Text('Change'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// The languages the work can be read in. Beside the group of four it
  /// holds only the others: the original and the learning language are
  /// columns of that group, and are not offered twice.
  Widget _languages(BuildContext context, ListenOffer? offer) {
    if (_versions case final v?) return _versionsSection(context, offer, v);
    final theme = Theme.of(context);
    final translate = _translate;
    final four = offer != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(four ? 'Other languages' : 'Language',
            style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            // Buttons, not chips: a chip keeps one line and clips a long
            // label at large text ("Original · Engli" at 320dp, 2x).
            if (!four)
              _LanguageButton(
                key: const Key('lang-original'),
                label: 'Original · $_originalName',
                selected: _language.isOriginal,
                onPressed: () => _pickLanguage(const WorkLanguage.original()),
              ),
            for (final t in _translations)
              if (!four || t.tag != offer.lang)
                _LanguageButton(
                key: Key('lang-${t.tag}'),
                label: languageNameOf(t.tag),
                selected: _language == t,
                onPressed: () => _pickLanguage(t),
              ),
            OutlinedButton.icon(
              key: const Key('lang-translate'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.translate),
              label: const Text('Translate…'),
              onPressed: translate,
            ),
          ],
        ),
        if (translate == null && !_isAudiobook)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _isAudio && !_transcribed
                  ? _canTranscribe
                        ? 'Translating needs a transcript first.'
                        : 'Translating needs a transcript, and this device '
                              'can’t transcribe.'
                  : 'This device can’t translate offline.',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  /// "This episode in other languages" (board-0130): the original and
  /// every other language it has, one row each, saying whether that
  /// language's audio is on this phone. It takes the place of the
  /// Language section on an episode, so no language shows twice. A
  /// language with audio goes to its episode and plays it; a text-only
  /// one is read, as a translation always was; this episode's own row
  /// chooses its own text.
  Widget _versionsSection(
      BuildContext context, ListenOffer? offer, EpisodeVersions v) {
    final theme = Theme.of(context);
    final translate = _translate;
    final originalLang = v.original.lang ?? _feed?.language;
    final originalBare = originalLang == null ? null : _bare(originalLang);
    final texts = <String, WorkLanguage>{};
    for (final t in _translations) {
      // The sentence-by-sentence translation first, as Read prefers.
      final tag = _bare(t.tag!);
      if (!texts.containsKey(tag) || texts[tag]!.layer) texts[tag] = t;
    }
    final langs = [
      for (final l in {...v.made.keys, ...texts.keys})
        if (l != originalBare &&
            // The group above holds the learning language's text.
            !(offer != null && l == offer.lang && v.made[l] == null))
          l,
    ]..sort((a, b) => languageNameOf(a).compareTo(languageNameOf(b)));

    Widget row({
      required Key key,
      required String lang,
      required String status,
      required bool audio,
      bool selected = false,
      bool goes = false,
      required VoidCallback onTap,
    }) =>
        ListTile(
          key: key,
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: Icon(audio
              ? Icons.headphones_outlined
              : Icons.chrome_reader_mode_outlined),
          title: Text(languageNameOf(lang)),
          subtitle: Text(status),
          selected: selected,
          trailing: goes
              ? const Icon(Icons.chevron_right)
              : selected
                  ? const Icon(Icons.check)
                  : null,
          onTap: onTap,
        );

    final here = _isOriginal;
    final rows = <Widget>[
      row(
        key: const Key('lang-original'),
        lang: originalLang ?? '',
        status: here ? 'This episode, the original' : 'The original',
        audio: true,
        selected: here && _language.isOriginal,
        goes: !here,
        onTap: here
            ? () => _pickLanguage(const WorkLanguage.original())
            : () => _openVersion(v.original.id, play: true),
      ),
      for (final l in langs)
        if (v.made[l] case final made? when made.workId == _work.id)
          row(
            key: Key('lang-$l'),
            lang: l,
            status: made.audio
                ? 'This episode, its audio is on this phone'
                : 'This episode, its audio was removed',
            audio: made.audio,
            selected: _language.isOriginal,
            onTap: () => _pickLanguage(const WorkLanguage.original()),
          )
        else if (v.made[l] case final made? when made.audio)
          row(
            key: Key('lang-$l'),
            lang: l,
            status: 'Audio on this phone',
            audio: true,
            goes: true,
            onTap: () => _openVersion(made.workId, play: true),
          )
        else if (v.made[l] case final made?)
          row(
            key: Key('lang-$l'),
            lang: l,
            status: 'Text only, its audio was removed',
            audio: false,
            selected: texts[l] != null && _language == texts[l],
            goes: texts[l] == null,
            onTap: texts[l] != null
                ? () => _pickLanguage(texts[l]!)
                : () => _openVersion(made.workId, play: false),
          )
        else
          row(
            key: Key('lang-$l'),
            lang: l,
            status: 'Text only, no audio yet',
            audio: false,
            selected: _language == texts[l],
            onTap: () => _pickLanguage(texts[l]!),
          ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('This episode in other languages',
            style: theme.textTheme.titleSmall),
        ...rows,
        const SizedBox(height: 4),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            key: const Key('lang-translate'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.translate),
            label: const Text('Translate…'),
            onPressed: translate,
          ),
        ),
        if (translate == null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              !_transcribed
                  ? _canTranscribe
                        ? 'Translating needs a transcript first.'
                        : 'Translating needs a transcript, and this device '
                              'can’t transcribe.'
                  : 'This device can’t translate offline.',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  Widget _visibleActions(BuildContext context) {
    final actions = _actions;
    final e = _episode;
    final id = _work.id;
    final audio = e != null && e.enclosureUrl != null;
    final buttons = <Widget>[
      if (audio && actions != null) ...[
        OutlinedButton.icon(
          key: Key('page-play-next-$id'),
          onPressed: () => _menu('play-next'),
          icon: const Icon(Icons.playlist_play),
          label: const Text('Play next'),
        ),
        OutlinedButton.icon(
          key: Key('page-play-last-$id'),
          onPressed: () => _menu('play-last'),
          icon: const Icon(Icons.playlist_add),
          label: const Text('Play last'),
        ),
      ],
      if (e != null && !_isKept)
        OutlinedButton.icon(
          key: Key('page-keep-$id'),
          onPressed: _keep,
          icon: const Icon(Icons.bookmark_add_outlined),
          label: const Text('Keep'),
        ),
      if (_showsTranscribe)
        OutlinedButton.icon(
          key: Key('page-transcribe-$id'),
          onPressed: _transcribe,
          icon: const Icon(Icons.subtitles_outlined),
          label: Text(_transcribeLabel),
        ),
      if (_showsDownload)
        OutlinedButton.icon(
          key: Key('page-download-$id'),
          onPressed: () => _menu('download'),
          icon: const Icon(Icons.download_outlined),
          label: const Text('Download'),
        ),
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 0,
      children: [
        for (final b in buttons)
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: b,
          ),
      ],
    );
  }

  List<Widget> _body(BuildContext context) {
    final theme = Theme.of(context);
    final notes = _notes?.html;
    final description = notes ?? _opening;
    final feed = _feed;
    return [
      Text(
        _isAudio ? 'Show notes' : 'About',
        style: theme.textTheme.titleMedium,
      ),
      const SizedBox(height: 8),
      if (description == null)
        Text(
          _isAudio
              ? 'No show notes yet. They arrive with the next refresh of '
                    'the feed, if it has any.'
              : 'Nothing to show yet.',
          key: const Key('no-notes'),
          style: theme.textTheme.bodyMedium,
        )
      else
        NotesView(
          key: const Key('work-notes'),
          html: description,
          foldable: true,
          onTimestamp: _isAudio && !_isAudiobook && _doors.player != null
              ? _seekTo
              : null,
          maxTimestamp: _notesEnd,
          onOpenLink: _doors.openLink,
        ),
      if (_captures.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text('Your captures', style: theme.textTheme.titleMedium),
        for (final c in _captures)
          ListTile(
            key: Key('capture-${c.id}'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.bookmark_outline),
            title: Text(formatClock(c.positionMs)),
            onTap: _isAudio && !_isAudiobook
                ? () => _seekTo(Duration(milliseconds: c.positionMs))
                : null,
          ),
      ],
      if (feed != null) ...[
        const SizedBox(height: 16),
        ListTile(
          key: const Key('from-show'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.podcasts),
          title: Text('From ${feed.title.isEmpty ? 'this feed' : feed.title}'),
          trailing: _doors.openShow == null
              ? null
              : const Icon(Icons.chevron_right),
          onTap: _doors.openShow == null
              ? null
              : () => _doors.openShow!(context, feed),
        ),
      ],
    ];
  }
}

/// Stands in for the one tap's owner where there is none: nothing here
/// ever changes.
class _Still implements Listenable {
  const _Still();
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}

/// One language in the language row: filled and ticked when chosen. The
/// label wraps rather than clips.
class _LanguageButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onPressed;
  const _LanguageButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
    );
    final text = Text(label, softWrap: true);
    return Semantics(
      selected: selected,
      child: selected
          ? FilledButton.tonalIcon(
              style: style,
              onPressed: onPressed,
              icon: const Icon(Icons.check),
              label: text,
            )
          : OutlinedButton(style: style, onPressed: onPressed, child: text),
    );
  }
}

/// The notes on their own, for Read on an episode with no transcript:
/// show notes are the text it has, and transcribing is offered beside
/// them.
class NotesScreen extends StatelessWidget {
  final String title;
  final String? html;
  final void Function(Duration at)? onTimestamp;
  final Duration? maxTimestamp;
  final Future<void> Function(Uri uri)? onOpenLink;
  final String transcribeLabel;
  final Future<void> Function()? onTranscribe;

  const NotesScreen({
    super.key,
    required this.title,
    required this.html,
    this.onTimestamp,
    this.maxTimestamp,
    this.onOpenLink,
    required this.transcribeLabel,
    this.onTranscribe,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notes = html;
    return Scaffold(
      appBar: AppBar(title: const Text('Show notes')),
      body: CappedBody(
        child: ListView(
          key: const Key('notes-screen'),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Text(title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            Card(
              key: const Key('transcribe-offer'),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      onTranscribe == null
                          ? 'No transcript. This device can’t make one.'
                          : 'No transcript yet. Transcribing runs on this '
                                'phone, and nothing leaves it.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    if (onTranscribe != null) ...[
                      const SizedBox(height: 8),
                      FilledButton.tonalIcon(
                        key: const Key('transcribe-now'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: onTranscribe,
                        icon: const Icon(Icons.subject),
                        label: Text(transcribeLabel),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (notes == null)
              Text(
                'This episode came with no show notes.',
                style: theme.textTheme.bodyLarge,
              )
            else
              NotesView(
                html: notes,
                onTimestamp: onTimestamp,
                maxTimestamp: maxTimestamp,
                onOpenLink: onOpenLink,
              ),
          ],
        ),
      ),
    );
  }
}
