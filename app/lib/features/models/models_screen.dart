/// "Models & storage" — the model manager AND the storage story (proposal-2
/// §9).
///
/// Lists the pinned registry: what each model is, exactly how big, whether
/// it is on this device. Downloading passes the ONE consent chokepoint
/// (bytes + metered warning), rides domovoi's resumable engine with an
/// honest ETA, can be paused (the partial stays), and can be deleted.
///
/// Below the models, the storage panel accounts for everything else the app
/// keeps on disk — cached episode audio, leftover decoded PCM, the database
/// file — with real byte counts and per-cache clear buttons. Clearing a
/// cache never reaches the spine: works, segments and positions live in the
/// database, which has no delete button here by design (data stays, cache
/// goes). Deleted transcripts and translations wait under Recently deleted
/// (1.5.9), each with a Restore.
library;

import 'asr_choice_section.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:openhearth_design/openhearth_design.dart';
import 'package:ml_runtime/ml_runtime.dart';

import '../../db/database.dart' show AppDatabase;
import '../../services/device_services.dart';
import '../episodes/episode_actions.dart';
import '../feeds/background/feed_check_section.dart';
import '../feeds/background/feed_check_settings.dart';
import '../reader/translation/language_names.dart';
import '../reader/translation/translation_service.dart';
import 'consent.dart';
import 'format.dart';
import 'model_store.dart';
import '../shared/capped_body.dart';
import '../storage/recently_deleted.dart';
import '../storage/storage_by_item_screen.dart';

export '../feeds/background/feed_check_section.dart' show FeedCheckSection;

/// Human names for the registry ids; unknown ids fall back to the id.
const Map<String, String> kModelLabels = {
  'whisper-tiny-ggml': 'Whisper Tiny: speech to text, multilingual',
  'whisper-base-ggml': 'Whisper Base: speech to text, multilingual',
  'whisper-small-ggml': 'Whisper Small: speech to text, multilingual',
  'silero-vad': 'Silence filter: voice activity detection',
  'supertonic-en-m1': 'Supertonic voice (English): read aloud, offline',
  'wiktionary-en-en-stardict': 'Wiktionary dictionary (English): word lookups, offline',
};

/// Translation pairs are named from the registry itself ("English to
/// Portuguese translation"): 25 of them, and an id like
/// `opus-mt-en-ROMANCE` doesn't say which language it writes.
final Map<String, String> _translationLabels = {
  for (final s in ModelRegistry.starter().translationPairsAt(DeviceTier.t3))
    s.id: '${languageDisplayName(s.sourceLang!)} to '
        '${languageDisplayName(s.langs!.single)} translation, offline',
};

String modelLabel(String id) =>
    kModelLabels[id] ?? _translationLabels[id] ?? id;

/// The credit the translation models' licences ask for, shown with them:
/// OPUS-MT for every pair but one, and ElanMT-BT for English to Japanese,
/// which Trellis converted itself (ADR-0014's amendment).
const String translationModelsCredit =
    'Translation models: OPUS-MT by Helsinki-NLP (University of Helsinki), '
    'each under CC-BY 4.0 or Apache-2.0 as its row says. Converted to ONNX '
    'by Xenova and onnx-community. Source and licences: '
    'https://github.com/Helsinki-NLP/Opus-MT\n'
    'English to Japanese: ElanMT-BT by ELAN MITSUA Project / Abstract '
    'Engine, under CC BY-SA 4.0, converted to ONNX by Trellis. Source and '
    'licence: https://huggingface.co/Mitsua/elan-mt-bt-en-ja. The '
    'converted files, the licence text and the export recipe are kept at '
    'https://github.com/levitatingflyfisher/Trellis/releases/tag/'
    'models-enja-1, which is never deleted.';

class ModelsScreen extends StatefulWidget {
  final ModelStore store;
  final ModelRegistry registry;

  /// The device stack, for the storage panel's audio/PCM cache directories
  /// (their paths come from [DeviceServices.audioFileFor]/`pcmFileFor` — the
  /// ONE path authority). Optional: without it the panel is simply absent,
  /// so detached surfaces and existing call sites keep working.
  final DeviceServices? services;

  /// The database file, measured when reachable. Null (or a missing file —
  /// in-memory test dbs) skips the row gracefully.
  final File? databaseFile;

  /// The background-check switches (ADR-0018); null where the system can't
  /// run a check, and then the section is absent.
  final FeedCheckSettings? feedCheck;

  /// The library, for "Storage by item" (1.5.8); with [services], the
  /// entry shows. [actions] removes a download the way every list does.
  final AppDatabase? db;
  final int? profileId;
  final EpisodeActions? actions;

  /// Shows the episodes whose audio is on this phone, under Latest's chip
  /// (board-0131): the episode-audio row's first choice, before Clear all.
  /// Null leaves the row with Clear all only.
  final VoidCallback? onShowEpisodesOnPhone;

  const ModelsScreen({
    super.key,
    required this.store,
    required this.registry,
    this.services,
    this.databaseFile,
    this.feedCheck,
    this.db,
    this.profileId,
    this.actions,
    this.onShowEpisodesOnPhone,
  });

  @override
  State<ModelsScreen> createState() => _ModelsScreenState();
}

/// What the models door opens where local ML is not available (the web
/// tier — DeviceServices.localMlAvailable is false): a calm explanation
/// instead of a manager whose file operations would throw under dart2js.
/// Named for what this tier does, not what it lacks.
class WebTierModelsNotice extends StatelessWidget {
  const WebTierModelsNotice({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Models & storage')),
      body: CappedBody(child: Padding(
        key: const Key('web-tier-notice'),
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This is the web tier',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            const Text(
              'Reading, feeds, courses, study and backup all live here, '
              'in your browser’s own storage. Nothing leaves this '
              'device unless you export it.',
            ),
            const SizedBox(height: 12),
            const Text(
              'Downloading models and transcribing episodes ride the '
              'installed app, where the files and processors are yours '
              'to use. Your backup file carries everything across.',
            ),
          ],
        ),
      )),
    );
  }
}

class _RowState {
  bool downloaded = false;
  int partialBytes = 0;
  int missingBytes = 0;

  /// Some of the model is installed, nothing is mid-download, and the
  /// rest is missing: a file was re-pinned (1.5.9's smaller translation
  /// decoders), so the model is an update away, not a first download.
  bool updateOf(ModelSpec spec) =>
      !downloaded &&
      partialBytes == 0 &&
      missingBytes > 0 &&
      missingBytes < spec.sizeBytes;
  ModelDownload? active;
  StreamSubscription<ModelDownloadProgress>? sub;
  ModelDownloadProgress? progress;
}

class _ModelsScreenState extends State<ModelsScreen> {
  final Map<String, _RowState> _rows = {};
  int _audioBytes = 0;
  int _pcmBytes = 0;
  int? _dbBytes;
  List<DeletedSnapshot> _deleted = const [];

  /// Snapshots being restored: their buttons wait, so a second tap can't
  /// run a second restore that reports the first as "a newer transcript".
  final Set<String> _restoring = {};

  /// Recently deleted needs the library to restore into; without it (or
  /// on the web, which keeps no copies) the section is absent.
  RecentlyDeleted? get _bin =>
      widget.db == null ? null : widget.services?.recentlyDeleted;

  /// Cache roots, derived through the services' own path functions so the
  /// panel can never drift from where the caches actually live.
  Directory get _audioDir => widget.services!.audioFileFor(0, '').parent;
  Directory get _pcmDir => widget.services!.pcmFileFor(0).parent;

  @override
  void initState() {
    super.initState();
    _refresh();
    unawaited(topUpTranslationModels(widget.registry, widget.store)
        .then((_) => mounted ? _refresh() : null));
  }

  @override
  void dispose() {
    for (final r in _rows.values) {
      r.sub?.cancel();
    }
    super.dispose();
  }

  Future<void> _refresh() async {
    for (final spec in widget.registry.specs) {
      final row = _rows.putIfAbsent(spec.id, _RowState.new);
      row.downloaded = await widget.store.isDownloaded(spec);
      row.partialBytes = await widget.store.partialBytes(spec);
      row.missingBytes = await widget.store.missingBytes(spec);
    }
    if (widget.services != null) {
      _audioBytes = _dirBytes(_audioDir);
      _pcmBytes = _dirBytes(_pcmDir);
    }
    final dbFile = widget.databaseFile;
    // Under WAL, recent writes live in the -wal sibling until a checkpoint.
    _dbBytes = (dbFile != null && dbFile.existsSync())
        ? [
            for (final suffix in const ['', '-wal', '-shm'])
              if (File('${dbFile.path}$suffix').existsSync())
                File('${dbFile.path}$suffix').lengthSync(),
          ].fold<int>(0, (a, b) => a + b)
        : null;
    _deleted = await _bin?.list() ?? const [];
    if (mounted) setState(() {});
  }

  static int _dirBytes(Directory dir) {
    if (!dir.existsSync()) return 0;
    var sum = 0;
    for (final entry in dir.listSync(recursive: true)) {
      if (entry is File) sum += entry.lengthSync();
    }
    return sum;
  }

  /// A model's real disk usage. Installed files pass [ModelStore.isDownloaded]
  /// only at their exact pinned lengths, so the pinned total IS the on-disk
  /// truth; `.part` files are measured directly by [ModelStore.partialBytes].
  int _modelDiskBytes(ModelSpec spec) {
    final row = _rows[spec.id];
    if (row == null) return 0;
    if (row.downloaded) return spec.sizeBytes + row.partialBytes;
    // Whole files already installed count too: a pair waiting on an
    // update still holds its encoder and tokenizer.
    return spec.sizeBytes - row.missingBytes;
  }

  Future<void> _download(ModelSpec spec) async {
    final row0 = _rows[spec.id];
    final update = row0 != null && row0.updateOf(spec);
    final ok = await confirmDownload(
      context,
      items: [
        DownloadItem(update
            ? '${modelLabel(spec.id)} update '
                '(${formatBytes(row0.missingBytes)})'
            : '${modelLabel(spec.id)} (${formatBytes(spec.sizeBytes)})'),
      ],
    );
    if (!ok || !mounted) return;

    final row = _rows[spec.id]!;
    final download = widget.store.download(spec);
    row.active = download;
    row.progress = null;
    row.sub = download.progress.listen((p) {
      setState(() => row.progress = p);
    });
    setState(() {});
    try {
      await download.done;
    } on ModelIntegrityException catch (e) {
      _tell(e.message);
    } catch (e) {
      debugPrint('Model download stopped: $e');
      _tell('${ohFriendlyErrorMessage(e)} The download didn’t finish; '
          'what came down is kept, so trying again carries on from there.');
    } finally {
      // Never awaited: cancel() of a finished stream returns the root-zone
      // null future, which a widget test's fake clock can never resume.
      unawaited(row.sub?.cancel() ?? Future<void>.value());
      row.sub = null;
      row.active = null;
      row.progress = null;
      await _refresh();
    }
  }

  Future<void> _delete(ModelSpec spec) async {
    // A model is gigabytes to fetch again, so removing one keeps asking
    // first (the Peckish ruling on large downloads), with a label that
    // names the act.
    final ok = await showOhConfirm(
      context,
      title: 'Remove this model?',
      message: '${modelLabel(spec.id)} frees '
          '${formatBytes(_modelDiskBytes(spec))}. You can download it again '
          'anytime.',
      confirmLabel: 'Remove model',
      cancelLabel: 'Keep',
      destructive: true,
    );
    if (!ok) return;
    await widget.store.delete(spec);
    await _refresh();
  }

  /// One confirm, then the cache directory goes. Only ever pointed at the
  /// audio/PCM cache roots — the database is not offered here at all, which
  /// is how "deleting cache never touches works/segments" stays structural.
  Future<void> _clearCache({
    required String what,
    required Directory dir,
    required int bytes,
    required String reassurance,
  }) async {
    final ok = await showOhConfirm(
      context,
      title: 'Delete $what?',
      message: 'Frees ${formatBytes(bytes)}. $reassurance',
      confirmLabel: 'Delete $what',
      cancelLabel: 'Keep',
      destructive: true,
    );
    if (!ok) return;
    if (dir.existsSync()) await dir.delete(recursive: true);
    await _refresh();
  }

  void _tell(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Models & storage')),
      body: CappedBody(child: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Models run entirely on this device. Nothing you transcribe '
              'ever leaves it.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          for (final spec in widget.registry.specs)
            if (spec.task != ModelTask.translation) _modelTile(spec),
          // Which whisper model transcribes (1.6.0): the listener's own
          // choice, where there is a device to run one and a place to
          // keep the choice.
          if (widget.db != null && widget.services != null)
            AsrChoiceSection(
                db: widget.db!,
                registry: widget.registry,
                tier: widget.services!.tier),
          if (_translationSpecs.isNotEmpty) _translationSection(),
          if (widget.feedCheck case final feedCheck?)
            FeedCheckSection(settings: feedCheck),
          if (widget.services != null) ..._storageSection(),
        ],
      )),
    );
  }

  List<Widget> _storageSection() {
    final theme = Theme.of(context);
    final onDisk = widget.registry.specs
        .where((spec) => _modelDiskBytes(spec) > 0)
        .toList();
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
        child: Text('Storage', style: theme.textTheme.titleMedium),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Text(
          'Everything this app keeps on disk.',
          style: theme.textTheme.bodySmall,
        ),
      ),
      if ((widget.db, widget.profileId) case (final db?, final profileId?))
        Card(
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: ListTile(
            key: const Key('storage-by-item'),
            title: const Text('Storage by item'),
            subtitle: const Text(
                'Downloads, transcripts and translations, one item at a '
                'time.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => StorageByItemScreen(
                      db: db,
                      services: widget.services!,
                      profileId: profileId,
                      actions: widget.actions)));
              await _refresh();
            },
          ),
        ),
      if ((widget.db, _bin) case (final db?, final bin?)
          when _deleted.isNotEmpty)
        ..._recentlyDeleted(db, bin),
      for (final spec in onDisk)
        ListTile(
          key: Key('storage-model-${spec.id}'),
          dense: true,
          title: Text(
            modelLabel(spec.id),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text(formatBytes(_modelDiskBytes(spec))),
        ),
      _cacheTile(
        rowKey: const Key('storage-audio'),
        clearKey: const Key('storage-audio-clear'),
        clearLabel: 'Clear all',
        first: widget.onShowEpisodesOnPhone == null
            ? null
            : TextButton(
                key: const Key('storage-audio-episodes'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: widget.onShowEpisodesOnPhone,
                child: const Text('See episodes'),
              ),
        title: 'Episode audio',
        bytes: _audioBytes,
        onClear: () => _clearCache(
          what: 'cached episode audio',
          dir: _audioDir,
          bytes: _audioBytes,
          reassurance:
              'Episodes stay in your library and can be fetched again.',
        ),
      ),
      _cacheTile(
        rowKey: const Key('storage-pcm'),
        clearKey: const Key('storage-pcm-clear'),
        title: 'Decoded audio (PCM)',
        bytes: _pcmBytes,
        onClear: () => _clearCache(
          what: 'leftover decoded audio',
          dir: _pcmDir,
          bytes: _pcmBytes,
          reassurance:
              'It is rebuilt automatically the next time it is needed.',
        ),
      ),
      if (_dbBytes != null)
        Card(
          key: const Key('storage-db'),
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Library database',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  'Your works, positions and courses. Not a cache.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Text(
                  formatBytes(_dbBytes!),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      const SizedBox(height: 16),
    ];
  }

  /// One card per deleted transcript or translation, newest first: what it
  /// was, whose, and when, with Restore beside it. Delete now is the rare
  /// act, so it sits in the ⋮ and asks, since nothing brings it back.
  List<Widget> _recentlyDeleted(AppDatabase db, RecentlyDeleted bin) {
    final theme = Theme.of(context);
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text('Recently deleted',
            key: const Key('recently-deleted'),
            style: theme.textTheme.titleSmall),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Text(
          'Transcripts and translations you delete wait here for 30 days, '
          'then go for good.',
          style: theme.textTheme.bodySmall,
        ),
      ),
      for (final s in _deleted)
        Card(
          key: Key('deleted-${s.id}'),
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 4, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.workTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  '${s.label} · '
                  '${formatDay(s.deletedAt.millisecondsSinceEpoch)} · '
                  'about ${formatBytes(s.bytes)}',
                  style: theme.textTheme.bodySmall,
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      TextButton(
                        key: Key('deleted-restore-${s.id}'),
                        onPressed: _restoring.contains(s.id)
                            ? null
                            : () => _restore(db, bin, s),
                        child: const Text('Restore'),
                      ),
                      PopupMenuButton<String>(
                        key: Key('deleted-menu-${s.id}'),
                        tooltip: 'More',
                        enabled: !_restoring.contains(s.id),
                        onSelected: (_) => _deleteNow(bin, s),
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'delete-now',
                            key: Key('deleted-delete-${s.id}'),
                            child: const Text('Delete now'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
    ];
  }

  Future<void> _restore(
      AppDatabase db, RecentlyDeleted bin, DeletedSnapshot s) async {
    // A tap already on its way before the button redrew is let go here.
    if (!_restoring.add(s.id)) return;
    setState(() {});
    String message;
    try {
      message = await restoreDeleted(db, bin, s);
    } catch (e) {
      // restoreDeleted words its own failures; this is the last net, so
      // a tap never ends in silence.
      debugPrint('Recently deleted: restore of ${s.id} failed: $e');
      message = 'Couldn’t restore it: something went wrong, so nothing '
          'changed. The copy is kept.';
    } finally {
      _restoring.remove(s.id);
    }
    await _refresh();
    _tell(message);
  }

  Future<void> _deleteNow(RecentlyDeleted bin, DeletedSnapshot s) async {
    if (_restoring.contains(s.id)) return;
    final ok = await showOhConfirm(
      context,
      title: 'Delete for good?',
      message: '“${s.workTitle}”: ${s.label}. It can’t be restored after '
          'this.',
      confirmLabel: 'Delete now',
      cancelLabel: 'Keep',
      destructive: true,
    );
    if (!ok) return;
    await bin.discard(s.id);
    await _refresh();
  }

  /// Same card shape as the model tiles, so the storage rows survive large
  /// text scales the same way (button below the text, never crammed into a
  /// ListTile trailing).
  Widget _cacheTile({
    required Key rowKey,
    required Key clearKey,
    required String title,
    required int bytes,
    required Future<void> Function() onClear,
    String clearLabel = 'Clear',
    Widget? first,
  }) {
    final theme = Theme.of(context);
    return Card(
      key: rowKey,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 2),
            Text(formatBytes(bytes), style: theme.textTheme.bodySmall),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: [
                  ?first,
                  TextButton(
                    key: clearKey,
                    onPressed: bytes == 0 ? null : onClear,
                    child: Text(clearLabel),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<ModelSpec> get _translationSpecs => [
        for (final s in widget.registry.specs)
          if (s.task == ModelTask.translation) s,
      ];

  /// One folded section for the translation pairs: there are two per
  /// language, and the reader's Translate sheet downloads them as needed,
  /// so here they are for looking up and removing, not the main list.
  Widget _translationSection() {
    final specs = _translationSpecs;
    final downloaded = specs.where((s) => _rows[s.id]?.downloaded ?? false);
    final updates =
        specs.where((s) => _rows[s.id]?.updateOf(s) ?? false).length;
    final theme = Theme.of(context);
    return ExpansionTile(
      key: const Key('models-translation'),
      title: const Text('Translation languages'),
      subtitle: Text(
          '${downloaded.length} of ${specs.length} downloaded'
          '${updates == 0 ? '' : ', $updates update${updates == 1 ? '' : 's'} available'}'
          '. Translate in the reader downloads what it needs.'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(translationModelsCredit,
              key: const Key('opus-mt-credit'),
              style: theme.textTheme.bodySmall),
        ),
        for (final spec in specs) _modelTile(spec),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _modelTile(ModelSpec spec) {
    final theme = Theme.of(context);
    final row = _rows[spec.id] ?? _RowState();
    final downloading = row.active != null;
    final update = !downloading && row.updateOf(spec);

    final Widget stateLine;
    if (downloading) {
      final p = row.progress;
      final eta = formatEta(p?.etaMs);
      stateLine = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(
            key: Key('model-progress-${spec.id}'),
            value: p == null ? null : p.receivedBytes / p.totalBytes,
          ),
          const SizedBox(height: 4),
          Text(
            '${formatBytes(p?.receivedBytes ?? 0)} of '
            '${formatBytes(spec.sizeBytes)}${eta.isEmpty ? '' : ' · $eta'}',
            style: theme.textTheme.bodySmall,
          ),
        ],
      );
    } else if (row.downloaded) {
      stateLine = Text(
        'On this device',
        key: Key('model-state-${spec.id}'),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      );
    } else if (update) {
      stateLine = Text(
        'Update available: ${formatBytes(row.missingBytes)}',
        key: Key('model-state-${spec.id}'),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      );
    } else if (row.partialBytes > 0) {
      stateLine = Text(
        'Paused: ${formatBytes(row.partialBytes)} of '
        '${formatBytes(spec.sizeBytes)} kept',
        key: Key('model-state-${spec.id}'),
        style: theme.textTheme.bodySmall,
      );
    } else {
      stateLine = Text(
        'Not downloaded',
        key: Key('model-state-${spec.id}'),
        style: theme.textTheme.bodySmall,
      );
    }

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(modelLabel(spec.id), style: theme.textTheme.titleSmall),
            const SizedBox(height: 2),
            Text(
              '${formatBytes(spec.sizeBytes)} · ${spec.licenses.join(', ')}',
              style: theme.textTheme.bodySmall,
            ),
            if (spec.convertedFrom case final from?)
              Text(
                'Converted by Trellis from $from',
                key: Key('model-converted-${spec.id}'),
                style: theme.textTheme.bodySmall,
              ),
            const SizedBox(height: 8),
            stateLine,
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                children: [
                  if (downloading)
                    TextButton(
                      key: Key('model-cancel-${spec.id}'),
                      onPressed: row.active!.cancel,
                      child: const Text('Pause'),
                    )
                  else if (row.downloaded)
                    TextButton(
                      key: Key('model-delete-${spec.id}'),
                      onPressed: () => _delete(spec),
                      child: const Text('Remove'),
                    )
                  else if (update) ...[
                    TextButton(
                      key: Key('model-delete-${spec.id}'),
                      onPressed: () => _delete(spec),
                      child: const Text('Remove'),
                    ),
                    TextButton(
                      key: Key('model-download-${spec.id}'),
                      onPressed: () => _download(spec),
                      child: const Text('Update'),
                    ),
                  ] else
                    TextButton(
                      key: Key('model-download-${spec.id}'),
                      onPressed: () => _download(spec),
                      child: Text(row.partialBytes > 0 ? 'Resume' : 'Download'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
