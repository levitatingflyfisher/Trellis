/// One page per work (1.5.4): an episode, a book, an article or a note.
/// Every row's tap opens it (`WorkDoors.open`); a row's Play still plays
/// at once and never comes here.
///
/// No mode is primary: Listen, Read and (for video) Watch sit side by
/// side at equal weight, and a mode that can't work says why instead of
/// hiding. The page opens on the mode and language last used for this
/// work, so coming back is one tap from where it was left.
library;

export '../transcribe/job_cards.dart' show transcribeEstimate;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:openhearth_design/openhearth_design.dart';

import '../transcribe/job_cards.dart';
import '../../db/database.dart' hide Alignment;
import '../episodes/episode_actions.dart';
import '../models/format.dart';
import '../reader/translation/language_names.dart';
import '../river/river_triage.dart';
import '../shared/capped_body.dart';
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
  final base = code.trim().toLowerCase().split(RegExp('[-_]')).first;
  return languageDisplayName(base);
}

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
  bool _loaded = false;

  WorkDoors get _doors => widget.doors;
  AppDatabase get _db => _doors.db;
  EpisodeActions? get _actions => _doors.actions;
  WorkEntry get _entry => (work: _work, episode: _episode);
  bool get _isAudio => !isTextWork(_work, _episode);
  bool get _isAudiobook => _work.kind == 'audiobook';
  bool get _transcribed => _facts?.transcribed ?? false;

  @override
  void initState() {
    super.initState();
    _markSeen();
    _load();
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
    final actions = _actions;
    final facts = WorkRowFacts.of(
      work,
      episode,
      state,
      downloaded: episode != null && (actions?.isDownloaded(episode) ?? false),
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
  String? get _readBlocked {
    if (_isAudiobook) return 'An audiobook has no text to read.';
    if (_isAudio &&
        _transcribed &&
        !_doors.readerDoors.canOpenTranscript &&
        _language.isOriginal) {
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
      // Karaoke has no translation view; the reader does.
      await _doors.read(
        context,
        _entry,
        layerLang: _language.layer ? _language.tag : null,
      );
    }
    await _load();
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
    if (!l.isOriginal && _readBlocked == null) await _read();
  }

  /// Today's translate entry points: the reader's Translate sheet for
  /// anything with text (it downloads what's missing), and
  /// transcribe-and-translate for an episode without a transcript.
  VoidCallback? get _translate {
    if (_isAudiobook) return null;
    if (_isAudio && !_transcribed) {
      if (!_canTranscribe) return null;
      return () async {
        final e = _episode;
        if (e == null) return;
        await _actions!.transcribe(context, (
          work: _work,
          episode: e,
        ), translate: true);
      };
    }
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

  /// The values of the shared items this page shows as buttons, which its
  /// ⋮ leaves out. Mirrors [_visibleActions] and the language row.
  Set<String> get _shownAsButtons => {
    if (_episode?.enclosureUrl != null) ...{'play-next', 'play-last'},
    if (_showsDownload) 'download',
    // Only an untranscribed episode's Translate… is the menu's act
    // (transcribe and translate); elsewhere it opens the reader's picker.
    if (_isAudio && !_transcribed) 'translate',
  };

  List<PopupMenuEntry<String>> _menuItems() {
    final actions = _actions;
    final id = _work.id;
    final extras = <PopupMenuEntry<String>>[
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
                    _modes(context),
                    const SizedBox(height: 16),
                    _languages(context),
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

  Widget _modes(BuildContext context) {
    final theme = Theme.of(context);
    final listenWhy = _listenBlocked;
    final readWhy = _readBlocked;
    const watchWhy = 'Video plays as sound for now: Listen plays it.';
    Widget button(
      WorkMode mode,
      IconData icon,
      String label,
      String? why,
      VoidCallback onPressed,
    ) {
      final selected = _mode == mode;
      final style = ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size.fromHeight(56)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 8),
        ),
      );
      final child = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon),
          const SizedBox(height: 2),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      );
      final action = why == null ? onPressed : null;
      return Expanded(
        child: Semantics(
          key: selected ? const Key('mode-selected') : null,
          selected: selected,
          button: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: selected
                ? FilledButton(
                    key: Key('mode-${mode.name}'),
                    style: style,
                    onPressed: action,
                    child: child,
                  )
                : FilledButton.tonal(
                    key: Key('mode-${mode.name}'),
                    style: style,
                    onPressed: action,
                    child: child,
                  ),
          ),
        ),
      );
    }

    final reasons = [
      if (listenWhy != null) 'Listen: $listenWhy',
      if (readWhy != null) 'Read: $readWhy',
      if (_hasVideo) 'Watch: $watchWhy',
      if (_isAudio && !_isAudiobook && !_transcribed && readWhy == null)
        'No transcript yet: Read opens the show notes.',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            button(
              WorkMode.listen,
              Icons.headphones_outlined,
              'Listen',
              listenWhy,
              _listen,
            ),
            button(
              WorkMode.read,
              Icons.chrome_reader_mode_outlined,
              'Read',
              readWhy,
              _read,
            ),
            if (_hasVideo)
              button(
                WorkMode.watch,
                Icons.movie_outlined,
                'Watch',
                watchWhy,
                () {},
              ),
          ],
        ),
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

  Widget _languages(BuildContext context) {
    final theme = Theme.of(context);
    final translate = _translate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Language', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            // Buttons, not chips: a chip keeps one line and clips a long
            // label at large text ("Original · Engli" at 320dp, 2x).
            _LanguageButton(
              key: const Key('lang-original'),
              label: 'Original · $_originalName',
              selected: _language.isOriginal,
              onPressed: () => _pickLanguage(const WorkLanguage.original()),
            ),
            for (final t in _translations)
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
              // Without a transcript it transcribes first; the line below
              // says so.
              label: const Text('Translate…'),
              onPressed: translate,
            ),
          ],
        ),
        if (translate != null && _isAudio && !_transcribed)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Translate transcribes first, then translates into English.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (translate == null && !_isAudiobook)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _isAudio && !_transcribed
                  ? 'Translating needs a transcript, and this device can’t '
                        'transcribe.'
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
