/// "On this device" — the model manager AND the storage story (proposal-2
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
/// goes).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ml_runtime/ml_runtime.dart';

import '../../services/device_services.dart';
import 'consent.dart';
import 'format.dart';
import 'model_store.dart';

/// Human names for the registry ids; unknown ids fall back to the id.
const Map<String, String> kModelLabels = {
  'whisper-tiny-ggml': 'Whisper Tiny — speech to text, multilingual',
  'whisper-base-ggml': 'Whisper Base — speech to text, multilingual',
  'silero-vad': 'Silence filter — voice activity detection',
  'qwen2.5-0.5b-instruct-litert': 'Qwen 2.5 0.5B — small local assistant',
  'supertonic-en-m1': 'Supertonic voice (English) — read aloud, offline',
};

String modelLabel(String id) => kModelLabels[id] ?? id;

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

  const ModelsScreen(
      {super.key,
      required this.store,
      required this.registry,
      this.services,
      this.databaseFile});

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
      appBar: AppBar(title: const Text('On this device')),
      body: Padding(
        key: const Key('web-tier-notice'),
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('This is the web tier',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            const Text(
                'Reading, feeds, courses, study and backup all live here, '
                'in your browser’s own storage — nothing leaves this '
                'device unless you export it.'),
            const SizedBox(height: 12),
            const Text(
                'Downloading models and transcribing episodes ride the '
                'installed app, where the files and processors are yours '
                'to use. Your backup file carries everything across.'),
          ],
        ),
      ),
    );
  }
}

class _RowState {
  bool downloaded = false;
  int partialBytes = 0;
  ModelDownload? active;
  StreamSubscription<ModelDownloadProgress>? sub;
  ModelDownloadProgress? progress;
}

class _ModelsScreenState extends State<ModelsScreen> {
  final Map<String, _RowState> _rows = {};
  int _audioBytes = 0;
  int _pcmBytes = 0;
  int? _dbBytes;

  /// Cache roots, derived through the services' own path functions so the
  /// panel can never drift from where the caches actually live.
  Directory get _audioDir => widget.services!.audioFileFor(0, '').parent;
  Directory get _pcmDir => widget.services!.pcmFileFor(0).parent;

  @override
  void initState() {
    super.initState();
    _refresh();
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
    }
    if (widget.services != null) {
      _audioBytes = _dirBytes(_audioDir);
      _pcmBytes = _dirBytes(_pcmDir);
    }
    final dbFile = widget.databaseFile;
    _dbBytes = (dbFile != null && dbFile.existsSync())
        ? dbFile.lengthSync()
        : null;
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
    return (row.downloaded ? spec.sizeBytes : 0) + row.partialBytes;
  }

  Future<void> _download(ModelSpec spec) async {
    final ok = await confirmDownload(context, items: [
      DownloadItem('${modelLabel(spec.id)} (${formatBytes(spec.sizeBytes)})'),
    ]);
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
      _tell("The download didn't finish — your progress is kept. ($e)");
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('delete-model-dialog'),
        title: const Text('Remove this model?'),
        content: Text('${modelLabel(spec.id)} frees '
            '${formatBytes(spec.sizeBytes)}. You can download it again '
            'anytime.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Keep')),
          FilledButton(
              key: const Key('delete-model-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.store.delete(spec);
    await _refresh();
  }

  /// One confirm, then the cache directory goes. Only ever pointed at the
  /// audio/PCM cache roots — the database is not offered here at all, which
  /// is how "deleting cache never touches works/segments" stays structural.
  Future<void> _clearCache(
      {required String what,
      required Directory dir,
      required int bytes,
      required String reassurance}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('storage-clear-dialog'),
        title: Text('Delete $what?'),
        content: Text('Frees ${formatBytes(bytes)}. $reassurance'),
        actions: [
          TextButton(
              key: const Key('storage-clear-cancel'),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Keep')),
          FilledButton(
              key: const Key('storage-clear-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    if (dir.existsSync()) await dir.delete(recursive: true);
    await _refresh();
  }

  void _tell(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('On this device')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Models run entirely on this device. Nothing you transcribe '
              'ever leaves it.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          for (final spec in widget.registry.specs) _modelTile(spec),
          if (widget.services != null) ..._storageSection(),
        ],
      ),
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
        child: Text('Everything this app keeps on disk.',
            style: theme.textTheme.bodySmall),
      ),
      for (final spec in onDisk)
        ListTile(
          key: Key('storage-model-${spec.id}'),
          dense: true,
          title: Text(modelLabel(spec.id),
              maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: Text(formatBytes(_modelDiskBytes(spec))),
        ),
      _cacheTile(
        rowKey: const Key('storage-audio'),
        clearKey: const Key('storage-audio-clear'),
        title: 'Episode audio',
        bytes: _audioBytes,
        onClear: () => _clearCache(
            what: 'cached episode audio',
            dir: _audioDir,
            bytes: _audioBytes,
            reassurance:
                'Episodes stay in your library and can be fetched again.'),
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
                'It is rebuilt automatically the next time it is needed.'),
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
                Text('Library database',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 2),
                Text('Your works, positions and courses — not a cache.',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 8),
                Text(formatBytes(_dbBytes!),
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ),
      const SizedBox(height: 16),
    ];
  }

  /// Same card shape as the model tiles, so the storage rows survive large
  /// text scales the same way (button below the text, never crammed into a
  /// ListTile trailing).
  Widget _cacheTile(
      {required Key rowKey,
      required Key clearKey,
      required String title,
      required int bytes,
      required Future<void> Function() onClear}) {
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
              child: TextButton(
                key: clearKey,
                onPressed: bytes == 0 ? null : onClear,
                child: const Text('Clear'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modelTile(ModelSpec spec) {
    final theme = Theme.of(context);
    final row = _rows[spec.id] ?? _RowState();
    final downloading = row.active != null;

    final Widget stateLine;
    if (downloading) {
      final p = row.progress;
      final eta = formatEta(p?.etaMs);
      stateLine = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(
              key: Key('model-progress-${spec.id}'),
              value: p == null ? null : p.receivedBytes / p.totalBytes),
          const SizedBox(height: 4),
          Text(
            '${formatBytes(p?.receivedBytes ?? 0)} of '
            '${formatBytes(spec.sizeBytes)}${eta.isEmpty ? '' : ' · $eta'}',
            style: theme.textTheme.bodySmall,
          ),
        ],
      );
    } else if (row.downloaded) {
      stateLine = Text('On this device',
          key: Key('model-state-${spec.id}'),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.primary));
    } else if (row.partialBytes > 0) {
      stateLine = Text(
          'Paused — ${formatBytes(row.partialBytes)} of '
          '${formatBytes(spec.sizeBytes)} kept',
          key: Key('model-state-${spec.id}'),
          style: theme.textTheme.bodySmall);
    } else {
      stateLine = Text('Not downloaded',
          key: Key('model-state-${spec.id}'), style: theme.textTheme.bodySmall);
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
                  else
                    TextButton(
                      key: Key('model-download-${spec.id}'),
                      onPressed: () => _download(spec),
                      child: Text(
                          row.partialBytes > 0 ? 'Resume' : 'Download'),
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
