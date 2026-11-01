/// One page per work (1.5.4): an episode, a book, an article or a note.
/// Every row's tap opens it (`WorkDoors.open`); a row's Play still plays
/// at once and never comes here.
///
/// One obvious main action (board-0161, owner: "clicking an episode is
/// insane when there are immediately 12 buttons"): Play for audio, Read
/// for a text. Beside it at most three: Read, Queue and Download for an
/// episode; Listen for a text. Below them the language list is the one
/// switch for listening and reading together: Play plays the chosen
/// language's made audio when it is on the phone, Read reads its text.
/// Everything else is in the ⋮. No control is shown greyed out: where
/// something is not offered, one plain line says why.
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
import '../transcribe/transcript_so_far.dart';
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
  /// The listener picked a language on this page (this visit): the
  /// default no longer applies.
  bool _languageChosenHere = false;
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

  /// How far a transcript still being made has got; null once it is
  /// whole. Part of one opens in Read, but Translate waits for it all.
  TranscriptMaking? get _making => _facts?.making;
  bool get _wholeTranscript => _transcribed && _making == null;

  TranscriptStage get _stage => !_transcribed
      ? TranscriptStage.none
      : switch (_making) {
          null => TranscriptStage.whole,
          (running: true, soFarMs: _) => TranscriptStage.makingNow,
          _ => TranscriptStage.stoppedPartWay,
        };

  /// The plain line that says why Translate waits, while it does.
  String? get _translateWaits => switch (_making) {
        final m? => translateWaitsLine(m, _episode?.durationMs),
        null => null,
      };

  StreamSubscription<Set<TableUpdate>>? _transcriptWrites;

  @override
  void initState() {
    super.initState();
    _markSeen();
    _load();
    // Jobs finish while the page is open (1.5.6): a transcript landing or
    // a download completing must change what the page offers without
    // leaving and coming back. A transcript shown as it is made is whole
    // only when its job ends, which writes the jobs table, not this one.
    _transcriptWrites = _db
        .tableUpdates(TableUpdateQuery.onAllTables([_db.alignments, _db.jobsTable]))
        .listen((_) {
      if (!_transcribed || _making != null) _load();
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
    final sentenceLangs = await _db.spineDao.translationLangsOf(id);
    final layerLangs = await _db.spineDao.layerLangsOf(id, kind: 'mt');
    final translations = [
      for (final l in sentenceLangs) WorkLanguage.translation(l),
      for (final l in layerLangs)
        if (!sentenceLangs.contains(l))
          WorkLanguage.translation(l, layer: true),
    ];
    final picked = work.readLang;
    var language = translations.firstWhere(
      (t) => t.tag == picked,
      orElse: () => const WorkLanguage.original(),
    );
    final captures = await _db.capturesDao.capturesOf(id);
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
    // A made language with no stored text of its own: Play plays it, and
    // Read reads the made episode's words.
    if (picked != null &&
        language.isOriginal &&
        versions?.withAudio(_bare(picked)) != null) {
      language = WorkLanguage.translation(picked);
    }
    // Play is in the learning language when that episode is made and its
    // audio is here, unless a language was picked (owner, 12 Nov).
    final learning = _jobs?.language;
    if (picked == null &&
        !_languageChosenHere &&
        learning != null &&
        versions != null &&
        versions.original.id == work.id &&
        versions.withAudio(learning) != null) {
      language = WorkLanguage.translation(learning);
      for (final t in translations) {
        if (_bare(t.tag!) == learning) {
          language = t;
          if (!t.layer) break;
        }
      }
    }
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
      _translations = translations;
      _language = language;
      _captures = captures;
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

  Future<void> _listen() async {
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
    if (_madeChosen case final made?
        when !_translations.any((t) => t.tag == _language.tag)) {
      final work = await _db.spineDao.workById(made.workId);
      final episode = await _db.feedsDao.episodeOf(made.workId);
      if (work != null && mounted) {
        await _doors.readFromRow(context, (work: work, episode: episode));
      }
      await _load();
      return;
    }
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

  /// Picking a language remembers it ([Works.readLang]) and makes it the
  /// language of both Play and Read (owner, 12 Nov: one language switch
  /// for listening and reading). It opens nothing by itself.
  Future<void> _choose(WorkLanguage l) async {
    _languageChosenHere = true;
    await _chooseLanguage(l);
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
    if (_isAudio && !_wholeTranscript) return null;
    if (_doors.readerDoors.translation == null) return null;
    return () async {
      await _doors.read(context, _entry, openTranslatePicker: true);
      await _load();
    };
  }

  // ───── actions ─────

  bool get _isKept => _work.persistence == 'work';

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
      case 'keep':
        await _keep();
        return;
      case 'learning-language':
        await _jobs?.pickLanguage(context, _offer?.languages ?? const [],
            of: (workLang: _work.lang, feedLang: _feed?.language));
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
  /// ⋮ leaves out. Mirrors [_actionsBlock].
  Set<String> get _shownAsButtons => {
    if (_offersQueue) ...{'play-next', 'play-last'},
    if (_offersDownload && !(_facts?.downloaded ?? false)) 'download',
  };

  List<PopupMenuEntry<String>> _menuItems() {
    final actions = _actions;
    final id = _work.id;
    final offer = _offer;
    final extras = <PopupMenuEntry<String>>[
      if (_episode != null && !_isKept)
        PopupMenuItem(
          key: Key('page-keep-$id'),
          value: 'keep',
          child: const Text('Keep'),
        ),
      if (offer != null && offer.lang != null && !offer.busy)
        PopupMenuItem(
          key: const Key('learning-language-change'),
          value: 'learning-language',
          child: const Text('Change learning language'),
        ),
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
      transcript: _stage,
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
                        final languages = _languageSection(context, offer);
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _actionsBlock(context, offer),
                            if (languages != null) ...[
                              const SizedBox(height: 24),
                              languages,
                            ],
                          ],
                        );
                      },
                    ),
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

  // ───── the page's actions (board-0161) ─────

  /// The made episode Play plays: the chosen language's, when its audio
  /// is on this phone and this is the original's page.
  MadeVersion? get _madeChosen {
    final v = _versions;
    final tag = _language.tag;
    if (v == null || !_isOriginal || tag == null) return null;
    return v.withAudio(_bare(tag));
  }

  Future<void> _play() async {
    if (_madeChosen case final made?) {
      final work = await _db.spineDao.workById(made.workId);
      if (work != null) await _doors.play(work);
    } else {
      await _doors.play(_work);
    }
    await _load();
  }

  bool get _offersQueue =>
      _actions != null && _episode?.enclosureUrl != null && !_isAudiobook;

  bool get _offersDownload =>
      _episode?.enclosureUrl != null &&
      !_isAudiobook &&
      (_actions?.canDownload ?? false);

  /// What Play plays, said under it in one line.
  String? _playCaption() {
    if (_downloading case final d?) return downloadingWords(d);
    if (_isAudiobook) return null;
    if (_madeChosen case final made?) {
      return '${languageNameOf(made.lang)}, made on this phone';
    }
    final tag = _language.tag;
    if (tag != null && _isOriginal) {
      return 'There is no ${languageNameOf(tag)} audio here, so Play is the '
          'original, in $_originalName.';
    }
    return _isOriginal || _versions == null
        ? '$_originalName, the original'
        : null;
  }

  /// One page-wide button: an icon above its word, at least 56 high.
  Widget _button({
    required Key key,
    required IconData? icon,
    Widget? iconWidget,
    required String label,
    required String tooltip,
    required VoidCallback onPressed,
    bool main = false,
  }) {
    final child = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        iconWidget ?? Icon(icon),
        const SizedBox(height: 4),
        Text(label, maxLines: 1, softWrap: false),
      ],
    );
    const style = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(48, 56)),
      padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 8, vertical: 8)),
    );
    final button = main
        ? FilledButton(
            key: key, style: style, onPressed: onPressed, child: child)
        : OutlinedButton(
            key: key, style: style, onPressed: onPressed, child: child);
    return Tooltip(message: tooltip, child: button);
  }

  /// Play next and Play last as one control.
  Widget _queueButton() {
    final id = _work.id;
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          key: Key('page-play-next-$id'),
          leadingIcon: const Icon(Icons.playlist_play),
          onPressed: () => _menu('play-next'),
          child: const Text('Play next'),
        ),
        MenuItemButton(
          key: Key('page-play-last-$id'),
          leadingIcon: const Icon(Icons.playlist_add),
          onPressed: () => _menu('play-last'),
          child: const Text('Play last'),
        ),
      ],
      builder: (context, controller, _) => _button(
        key: Key('page-queue-$id'),
        icon: Icons.queue_music_outlined,
        label: 'Queue',
        tooltip: 'Add to the Queue: play next or play last',
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }

  /// One download control: Download, Stop while it downloads, and
  /// Downloaded, which offers to remove it.
  Widget _downloadButton() {
    final id = _work.id;
    final key = Key('page-download-$id');
    if (_downloading case final d?) {
      return _button(
        key: key,
        icon: null,
        iconWidget: SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(
              value: downloadFraction(d), strokeWidth: 2.5),
        ),
        label: 'Stop',
        tooltip: '${downloadingWords(d)}. Stop the download',
        onPressed: () => _actions?.downloader?.cancel(id),
      );
    }
    if (_facts?.downloaded ?? false) {
      return _button(
        key: key,
        // The title's markers already say it is downloaded; the button
        // names what it does (a fresh reader took "Downloaded" for a
        // status that did nothing).
        icon: Icons.delete_outline,
        label: 'Remove download',
        tooltip: 'It is on this phone. Remove the download',
        onPressed: () => _menu('remove-download'),
      );
    }
    return _button(
      key: key,
      icon: Icons.download_outlined,
      label: 'Download',
      tooltip: 'Download it to this phone',
      onPressed: () => _menu('download'),
    );
  }

  /// The main action, the few beside it, and a plain line for anything
  /// not offered.
  Widget _actionsBlock(BuildContext context, ListenOffer? offer) {
    final theme = Theme.of(context);
    final lines = <String>[];
    Widget? main;
    final beside = <(String, Widget)>[];
    if (_isAudio) {
      if (_doors.player == null) {
        lines.add('Playing isn’t available here.');
      } else {
        final made = _madeChosen;
        final downloading = _downloading;
        main = _button(
          key: const Key('mode-listen'),
          main: true,
          icon: Icons.play_arrow,
          iconWidget: downloading == null
              ? null
              : SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(
                    value: downloadFraction(downloading),
                    strokeWidth: 2.5,
                    color: theme.colorScheme.onPrimary,
                  ),
                ),
          label: made == null ? 'Play' : 'Play in ${languageNameOf(made.lang)}',
          tooltip: made == null
              ? 'Play this episode'
              : 'Play the ${languageNameOf(made.lang)} audio',
          onPressed: _play,
        );
      }
      if (_readBlocked case final why?) {
        lines.add(why);
      } else {
        beside.add(('Read', _button(
          key: const Key('mode-read'),
          icon: Icons.chrome_reader_mode_outlined,
          label: 'Read',
          tooltip: _language.isOriginal
              ? 'Read it'
              : 'Read it in ${languageNameOf(_language.tag)}',
          onPressed: _read,
        )));
      }
      if (_offersQueue) beside.add(('Queue', _queueButton()));
      if (_offersDownload) {
        beside.add((
          (_facts?.downloaded ?? false) ? 'Remove download' : 'Download',
          _downloadButton()
        ));
      }
      if (_isAudio && !_isAudiobook && !_transcribed && _readBlocked == null) {
        lines.add('No transcript yet: Read opens the show notes.');
      }
      if (_facts?.video ?? false) {
        lines.add('Video plays as sound for now: Play plays it.');
      }
    } else {
      main = _button(
        key: const Key('mode-read'),
        main: true,
        icon: Icons.chrome_reader_mode_outlined,
        label: 'Read',
        tooltip: _language.isOriginal
            ? 'Read it'
            : 'Read it in ${languageNameOf(_language.tag)}',
        onPressed: _read,
      );
      beside.add(('Listen', _button(
        key: const Key('mode-listen'),
        icon: Icons.headphones_outlined,
        label: 'Listen',
        tooltip: 'Read it aloud',
        onPressed: _listen,
      )));
    }
    final caption = _isAudio && main != null ? _playCaption() : null;
    final muted = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?main,
        if (caption != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(caption,
                key: const Key('page-play-caption'),
                textAlign: TextAlign.center,
                style: muted),
          ),
        if (beside.isNotEmpty) ...[
          const SizedBox(height: 16),
          _grid(context, beside),
        ],
        for (final (i, line) in lines.indexed)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(line, key: Key('mode-reason-$i'), style: muted),
          ),
        // A running transcription shows here, under Read, not only on
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
        if (offer != null && (offer.busy || offer.failed))
          _jobStatus(theme, offer),
      ],
    );
  }

  /// The buttons beside the main one, on one line of equal cells; where
  /// their words can't all fit whole at this text size, one under
  /// another at full width instead, never cut.
  Widget _grid(BuildContext context, List<(String, Widget)> cells) =>
      LayoutBuilder(builder: (context, constraints) {
        const gap = 8.0;
        final cell =
            (constraints.maxWidth - gap * (cells.length - 1)) / cells.length;
        final style = Theme.of(context).textTheme.labelLarge;
        final scaler = MediaQuery.textScalerOf(context);
        var widest = 0.0;
        for (final (label, _) in cells) {
          final painter = TextPainter(
            text: TextSpan(text: label, style: style),
            textDirection: Directionality.of(context),
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          if (painter.width > widest) widest = painter.width;
          painter.dispose();
        }
        // The button's own padding, 8 a side, and a point to spare.
        if (widest + 17 > cell) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, (_, w)) in cells.indexed) ...[
                if (i > 0) const SizedBox(height: gap),
                w,
              ],
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (i, (_, w)) in cells.indexed) ...[
              if (i > 0) const SizedBox(width: gap),
              Expanded(child: w),
            ],
          ],
        );
      });

  /// What the learning language's job is doing, with Stop while it runs.
  Widget _jobStatus(ThemeData theme, ListenOffer offer) {
    final id = _work.id;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (offer.making)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
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
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ───── language: one switch for listening and reading ─────

  Widget _langRow({
    required Key key,
    required String title,
    required String status,
    required IconData icon,
    bool selected = false,
    bool goes = false,
    Widget? trailing,
    required VoidCallback onTap,
  }) =>
      ListTile(
        key: key,
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        minTileHeight: 56,
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(status),
        selected: selected,
        trailing: trailing ??
            (goes
                ? const Icon(Icons.chevron_right)
                : selected
                    ? const Icon(Icons.check)
                    : null),
        onTap: onTap,
      );

  /// Translate, as a row where it can run; otherwise the line that says
  /// why it can't (never a greyed button).
  List<Widget> _translateRow(ThemeData theme) {
    final translate = _translate;
    if (translate != null) {
      return [
        _langRow(
          key: const Key('lang-translate'),
          title: 'Translate…',
          status: 'Into another language',
          icon: Icons.translate,
          goes: true,
          onTap: translate,
        ),
      ];
    }
    if (_isAudiobook) return const [];
    return [
      Padding(
        key: const Key('lang-translate-why'),
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
        child: Text(
          _isAudio && !_transcribed
              ? _canTranscribe
                    ? 'Translating needs a transcript first. Transcribe is '
                          'in the menu at the top.'
                    : 'Translating needs a transcript, and this device '
                          'can’t transcribe.'
              : _translateWaits ?? 'This device can’t translate offline.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    ];
  }

  Widget? _languageSection(BuildContext context, ListenOffer? offer) {
    if (_isAudiobook) return null;
    final theme = Theme.of(context);
    final v = _versions;
    final rows = v == null ? _textLanguageRows() : _versionRows(v, offer);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          v == null ? 'Language' : 'This episode in other languages',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        ...rows,
        ..._translateRow(theme),
      ],
    );
  }

  List<Widget> _textLanguageRows() => [
        _langRow(
          key: const Key('lang-original'),
          title: _originalName,
          status: 'The original',
          icon: Icons.chrome_reader_mode_outlined,
          selected: _language.isOriginal,
          onTap: () => _choose(const WorkLanguage.original()),
        ),
        for (final t in _translations)
          _langRow(
            key: Key('lang-${t.tag}'),
            title: languageNameOf(t.tag),
            status: t.layer ? 'Translation of the transcript' : 'Translation',
            icon: Icons.translate,
            selected: _language == t,
            onTap: () => _choose(t),
          ),
      ];

  /// The episode in each language it has (board-0130), one row each,
  /// saying whether that language's audio is on this phone. On the
  /// original's page a row chooses the language for Play and Read; on a
  /// made episode's page the others are their own episodes, and go.
  List<Widget> _versionRows(EpisodeVersions v, ListenOffer? offer) {
    final originalLang = v.original.lang ?? _feed?.language;
    final originalBare = originalLang == null ? null : _bare(originalLang);
    final texts = <String, WorkLanguage>{};
    for (final t in _translations) {
      // The sentence-by-sentence translation first, as Read prefers.
      final tag = _bare(t.tag!);
      if (!texts.containsKey(tag) || texts[tag]!.layer) texts[tag] = t;
    }
    final learning = offer?.lang;
    // The learning language, when its audio isn't here yet, is the row
    // that makes it: the one tap, the same job as the row's second button.
    final makes = offer != null &&
        _isOriginal &&
        (learning == null || v.withAudio(learning) == null);
    final langs = [
      for (final l in {...v.made.keys, ...texts.keys})
        if (l != originalBare && !(makes && l == learning)) l,
    ]..sort((a, b) => languageNameOf(a).compareTo(languageNameOf(b)));
    final chosen = _language.tag == null ? null : _bare(_language.tag!);
    final here = _isOriginal;
    return [
      _langRow(
        key: const Key('lang-original'),
        title: languageNameOf(originalLang),
        status: here ? 'This episode, the original' : 'The original',
        icon: Icons.headphones_outlined,
        selected: here && _language.isOriginal,
        goes: !here,
        onTap: here
            ? () => _choose(const WorkLanguage.original())
            : () => _openVersion(v.original.id, play: true),
      ),
      for (final l in langs)
        if (v.made[l] case final made? when made.workId == _work.id)
          _langRow(
            key: Key('lang-$l'),
            title: languageNameOf(l),
            status: made.audio
                ? 'This episode, its audio is on this phone'
                : 'This episode, its audio was removed',
            icon: made.audio
                ? Icons.headphones_outlined
                : Icons.chrome_reader_mode_outlined,
            selected: true,
            onTap: () => _choose(const WorkLanguage.original()),
          )
        else if (!here && v.made[l] != null)
          _langRow(
            key: Key('lang-$l'),
            title: languageNameOf(l),
            status: v.made[l]!.audio
                ? 'Audio on this phone'
                : 'Text only, its audio was removed',
            icon: Icons.headphones_outlined,
            goes: true,
            onTap: () => _openVersion(v.made[l]!.workId,
                play: v.made[l]!.audio),
          )
        else
          _langRow(
            key: Key('lang-$l'),
            title: languageNameOf(l),
            status: switch (v.made[l]) {
              (audio: true, lang: _, workId: _) => texts[l] == null
                  ? 'Audio on this phone'
                  : 'Audio on this phone, and its text',
              (audio: false, lang: _, workId: _) =>
                'Text only, its audio was removed',
              null => 'Text only, no audio yet',
            },
            icon: v.made[l]?.audio ?? false
                ? Icons.headphones_outlined
                : Icons.chrome_reader_mode_outlined,
            selected: chosen == l,
            goes: texts[l] == null && !(v.made[l]?.audio ?? false),
            onTap: texts[l] != null
                ? () => _choose(texts[l]!)
                : v.made[l]!.audio
                    ? () => _choose(WorkLanguage.translation(l))
                    : () => _openVersion(v.made[l]!.workId, play: false),
          ),
      if (makes) _makeRow(offer, texts),
    ];
  }

  /// The learning language, not made yet: a tap chooses it (its text, if
  /// any, for Read) and makes its audio, which plays when it is ready.
  Widget _makeRow(ListenOffer offer, Map<String, WorkLanguage> texts) {
    final lang = offer.lang;
    final name = lang == null ? null : languageNameOf(lang);
    final text = lang == null ? null : texts[lang];
    return _langRow(
      key: const Key('listen-in-language'),
      title: name ?? 'Another language',
      status: offer.busy || offer.failed
          ? offer.line
          : name == null
              ? 'Choose a language to make this episode in'
              : text == null
                  ? 'Not made yet. Tap to make the $name audio'
                  : 'Text only. Tap to make the $name audio',
      icon: Icons.translate,
      selected: text != null && _language == text,
      trailing: offer.making
          ? SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(
                  value: offer.fraction, strokeWidth: 2.5),
            )
          : offer.waiting
              ? const Icon(Icons.hourglass_empty)
              : null,
      onTap: () async {
        if (text != null) await _choose(text);
        if (!mounted) return;
        await _jobs!.tap(context, _work, _episode!, feedLang: _feed?.language);
      },
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
