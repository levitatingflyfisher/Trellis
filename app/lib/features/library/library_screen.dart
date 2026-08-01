import 'package:comms_core/comms_core.dart';
import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../../net/io_fetcher.dart';
import '../../services/device_services.dart';
import '../intake/epub_intake.dart';
import '../intake/gutenberg_screen.dart';
import '../intake/paste_intake.dart';
import '../intake/url_intake.dart';
import '../reader/reader_screen.dart';
import '../reader/speech/speech_engine.dart';
import '../reader/speech/speech_temp_files.dart';

typedef _Entry = ({Work work, int segmentCount, Position? position});

/// One reader's works: pinned first, then newest; progress is the cursor
/// law's numerator over the segment count. The empty state is an invitation,
/// not a void (ADR-0003 — no guilt, no streaks).
class LibraryScreen extends StatefulWidget {
  final AppDatabase db;
  final Profile profile;
  final VoidCallback onSwitchProfile;

  /// Opens the "On this device" model manager; the shell wires it.
  final VoidCallback? onOpenModels;

  /// The HTTP seam for "From the web" intake. Optional so existing call
  /// sites keep compiling; when the shell does not pass one, the real
  /// [IoHttpFetcher] is built lazily on first use — tests always inject a
  /// ScriptedFetcher, so no test ever constructs a socket-capable client.
  final HttpFetcher? fetcher;

  /// The speak-mode voice, handed on to every reader this screen opens —
  /// null lets [ReaderScreen] fall back to the platform speaker.
  final TtsSpeaker? tts;

  /// The web tier's fetch-routing decision, handed on
  /// to the two web-fetching doors this screen opens — the
  /// [DeviceServices.localMlAvailable] threading pattern's sibling.
  final WebFetchLane lane;

  /// Whether this tier can run local ML at all — every reader this screen
  /// opens uses it to decide whether the neural-voice hint could ever be
  /// true (ADR-0006).
  final bool localMlAvailable;

  /// Resolves the neural voice for a work's language (ADR-0006) — the
  /// shell closes over `DeviceServices.resolveSpeechEngine`; null keeps
  /// every reader this screen opens on the system voice.
  final Future<SynthesisSpeechEngine?> Function({String? lang})?
      resolveSpeechEngine;

  /// Where a reader this screen opens writes per-sentence WAV temp files
  /// while speaking neurally — the shell closes over
  /// `DeviceServices.createSpeechTempFiles` (the location app start
  /// sweeps); null falls back to `ReaderScreen`'s own plain-systemTemp
  /// default.
  final SpeechTempFiles Function()? createSpeechTempFiles;

  const LibraryScreen(
      {super.key,
      required this.db,
      required this.profile,
      required this.onSwitchProfile,
      this.onOpenModels,
      this.fetcher,
      this.tts,
      this.lane = WebFetchLane.direct,
      this.localMlAvailable = true,
      this.resolveSpeechEngine,
      this.createSpeechTempFiles});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<_Entry>? _entries;

  SpineDao get _dao => widget.db.spineDao;

  late final HttpFetcher _fetcher = widget.fetcher ?? IoHttpFetcher();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final works = await _dao.worksOf(widget.profile.id);
    final entries = <_Entry>[
      for (final w in works)
        (
          work: w,
          segmentCount: await _dao.segmentCount(w.id),
          position:
              await _dao.position(profileId: widget.profile.id, workId: w.id),
        )
    ];
    entries.sort((a, b) {
      if (a.work.pinned != b.work.pinned) return a.work.pinned ? -1 : 1;
      return b.work.id.compareTo(a.work.id); // newest first
    });
    if (!mounted) return;
    setState(() => _entries = entries);
  }

  Future<void> _pasteText() async {
    final workId = await showPasteIntakeDialog(context,
        db: widget.db, profileId: widget.profile.id);
    if (workId != null) await _load();
  }

  Future<void> _importEpub() async {
    try {
      final workId =
          await pickAndImportEpub(db: widget.db, profileId: widget.profile.id);
      if (workId != null) await _load();
    } on FormatException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("That file couldn't be read as an EPUB.")));
    }
  }

  Future<void> _fromWeb() async {
    final workId = await Navigator.of(context).push<int>(MaterialPageRoute(
        builder: (_) => UrlIntakeScreen(
            db: widget.db,
            profileId: widget.profile.id,
            fetcher: _fetcher,
            lane: widget.lane)));
    if (workId != null) await _load();
  }

  Future<void> _fromGutenberg() async {
    final workId = await Navigator.of(context).push<int>(MaterialPageRoute(
        builder: (_) => GutenbergSearchScreen(
            db: widget.db,
            profileId: widget.profile.id,
            fetcher: _fetcher,
            lane: widget.lane)));
    if (workId != null) await _load();
  }

  void _addSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.content_paste),
              title: const Text('Paste text'),
              onTap: () {
                Navigator.pop(sheet);
                _pasteText();
              },
            ),
            ListTile(
              leading: const Icon(Icons.menu_book_outlined),
              title: const Text('Import an EPUB'),
              onTap: () {
                Navigator.pop(sheet);
                _importEpub();
              },
            ),
            ListTile(
              leading: const Icon(Icons.public),
              title: const Text('From the web'),
              onTap: () {
                Navigator.pop(sheet);
                _fromWeb();
              },
            ),
            ListTile(
              leading: const Icon(Icons.local_library_outlined),
              title: const Text('Project Gutenberg'),
              onTap: () {
                Navigator.pop(sheet);
                _fromGutenberg();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _togglePin(_Entry e) async {
    final pinning = !e.work.pinned;
    await _dao.setPinned(e.work.id, pinning);
    // A pin is the user's hand on the work (ADR-0002): it also promotes.
    if (pinning) await _dao.promoteWork(e.work.id);
    await _load();
  }

  Future<void> _remove(_Entry e) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text("Remove '${e.work.title}'?"),
        content:
            const Text('It leaves this library; nothing else is touched.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Keep it')),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Remove from library')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _dao.deleteWork(e.work.id);
    await _load();
  }

  Future<void> _open(_Entry e) async {
    // Resolved before the push (ADR-0006): the neural-voice hint and the
    // settings-escape menu both need to know whether a voice exists BEFORE
    // the reader ever shows its first frame — cheap (a directory-exists
    // check at most), never touched on a tier that can't run local ML.
    final resolver = widget.resolveSpeechEngine;
    final hasVoice = resolver == null
        ? false
        : await resolver(lang: e.work.lang) != null;
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ReaderScreen(
          db: widget.db,
          profileId: widget.profile.id,
          work: e.work,
          tts: widget.tts,
          offerNeuralVoice: widget.localMlAvailable && !hasVoice,
          resolveSpeechEngine: widget.resolveSpeechEngine,
          createSpeechTempFiles: widget.createSpeechTempFiles),
    ));
    await _load(); // progress may have moved
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          if (widget.onOpenModels != null)
            IconButton(
              key: const Key('open-models'),
              tooltip: 'On this device',
              icon: const Icon(Icons.memory_outlined),
              onPressed: widget.onOpenModels,
            ),
          TextButton.icon(
            key: const Key('profile-switcher'),
            onPressed: widget.onSwitchProfile,
            icon: const Icon(Icons.person_outline),
            // AppBar actions get intrinsic width — without a bound the
            // ellipsis never engages and long names overflow at 320dp.
            label: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 108),
              child: Text(widget.profile.name,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  softWrap: false),
            ),
          ),
        ],
      ),
      floatingActionButton: (entries == null || entries.isEmpty)
          ? null
          : FloatingActionButton.extended(
              onPressed: _addSheet,
              icon: const Icon(Icons.add),
              label: const Text('Add')),
      body: switch (entries) {
        null => const Center(child: CircularProgressIndicator()),
        [] => _EmptyState(
            onPaste: _pasteText,
            onEpub: _importEpub,
            onWeb: _fromWeb,
            onGutenberg: _fromGutenberg),
        _ => ListView.builder(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: entries.length,
            itemBuilder: (_, i) => _workTile(entries[i]),
          ),
      },
    );
  }

  Widget _workTile(_Entry e) {
    final progress = e.segmentCount == 0
        ? 0.0
        : ((e.position?.segmentIdx ?? 0) / e.segmentCount).clamp(0.0, 1.0);
    return ListTile(
      onTap: () => _open(e),
      leading: Icon(switch (e.work.kind) {
        'book' => Icons.menu_book_outlined,
        'article' => Icons.article_outlined,
        _ => Icons.notes_outlined,
      }),
      title: Text(e.work.title, overflow: TextOverflow.ellipsis, maxLines: 2),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: LinearProgressIndicator(
            value: progress, borderRadius: BorderRadius.circular(2)),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (e.work.pinned)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Icon(Icons.push_pin, size: 18),
            ),
          PopupMenuButton<String>(
            key: Key('work-menu-${e.work.id}'),
            onSelected: (v) => switch (v) {
              'pin' => _togglePin(e),
              _ => _remove(e),
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                  value: 'pin',
                  child: Text(e.work.pinned ? 'Unpin' : 'Pin')),
              const PopupMenuItem(value: 'remove', child: Text('Remove')),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onPaste;
  final VoidCallback onEpub;
  final VoidCallback onWeb;
  final VoidCallback onGutenberg;
  const _EmptyState(
      {required this.onPaste,
      required this.onEpub,
      required this.onWeb,
      required this.onGutenberg});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.eco_outlined,
                  size: 56, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text('Nothing on the trellis yet.',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text('Bring something you would like to read.',
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton.icon(
                  onPressed: onPaste,
                  icon: const Icon(Icons.content_paste),
                  label: const Text('Paste text')),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                  onPressed: onEpub,
                  icon: const Icon(Icons.menu_book_outlined),
                  label: const Text('Import an EPUB')),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                  onPressed: onWeb,
                  icon: const Icon(Icons.public),
                  label: const Text('From the web')),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                  onPressed: onGutenberg,
                  icon: const Icon(Icons.local_library_outlined),
                  label: const Text('Project Gutenberg')),
            ],
          ),
        ),
      ),
    );
  }
}
