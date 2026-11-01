/// The one tap (1.6.0): on an episode's page, "Listen in Spanish". The
/// first press asks the learning language once; after that the button
/// carries it. While the chain works the bar says which stage it is at;
/// when the spoken episode exists the same button plays it.
library;

import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../models/consent.dart';
import '../reader/translation/language_names.dart';
import 'listen_chain.dart';

/// The device setting: the language the listener is learning.
const learningLanguageKey = 'learning_language';

class ListenInLanguageBar extends StatefulWidget {
  const ListenInLanguageBar({
    super.key,
    required this.db,
    required this.chain,
    required this.work,
    required this.languages,
    required this.downloadsFor,
    required this.onPlay,
  });

  final AppDatabase db;
  final ListenChain chain;
  final Work work;

  /// The languages on offer, as bare tags.
  final List<String> languages;

  /// What starting would download, for the one consent dialog.
  final Future<List<DownloadItem>> Function(String lang) downloadsFor;

  /// The spoken episode exists: play it. [justMade] is true at the end
  /// of the job, which may have run for half an hour while the listener
  /// went on to something else, and false for a tap on one already made.
  final Future<void> Function(int spokenWorkId, {required bool justMade})
      onPlay;

  @override
  State<ListenInLanguageBar> createState() => _ListenInLanguageBarState();
}

class _ListenInLanguageBarState extends State<ListenInLanguageBar> {
  String? _lang;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final stored = await widget.db.deviceSettingsDao.read(learningLanguageKey);
    if (!mounted) return;
    setState(() {
      _lang = widget.languages.contains(stored) ? stored : null;
      _loaded = true;
    });
  }

  Future<String?> _pick() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        key: const Key('learning-language-dialog'),
        title: const Text('Which language are you learning?'),
        children: [
          for (final l in widget.languages)
            SimpleDialogOption(
              key: Key('learning-language-$l'),
              onPressed: () => Navigator.pop(context, l),
              child: Text(languageDisplayName(l)),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 12, 24, 0),
            child: Text('These are the languages Trellis can save as '
                'audio on this device. Other languages can be translated '
                'and read aloud from an episode’s Read page.'),
          ),
        ],
      ),
    );
    if (picked == null) return null;
    await widget.db.deviceSettingsDao.write(learningLanguageKey, picked);
    if (mounted) setState(() => _lang = picked);
    return picked;
  }

  Future<void> _go() async {
    final lang = _lang ?? await _pick();
    if (lang == null || !mounted) return;
    final made = await widget.chain.madeEpisodeOf(widget.work.id, lang);
    if (!mounted) return;
    if (made != null) {
      await widget.onPlay(made, justMade: false);
      return;
    }
    final items = await widget.downloadsFor(lang);
    if (!mounted) return;
    if (items.isNotEmpty && !await confirmDownload(context, items: items)) {
      return;
    }
    final id = await widget.chain.start(widget.work, lang);
    if (id != null) await widget.onPlay(id, justMade: true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || widget.languages.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.chain,
      builder: (context, _) {
        final state = widget.chain.stateOf(widget.work.id);
        final lang = _lang;
        final running = state != null && state.running;
        final label = lang == null
            ? 'Listen in another language'
            : 'Listen in ${languageDisplayName(lang)}';
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      key: const Key('listen-in-language'),
                      onPressed: running ? null : _go,
                      icon: const Icon(Icons.translate),
                      label: Text(label),
                    ),
                  ),
                  if (running)
                    TextButton(
                      key: const Key('listen-in-language-stop'),
                      onPressed: () => widget.chain.cancel(widget.work.id),
                      child: const Text('Stop'),
                    )
                  else if (lang != null && widget.languages.length > 1)
                    TextButton(
                      key: const Key('learning-language-change'),
                      onPressed: _pick,
                      child: const Text('Change'),
                    ),
                ],
              ),
              if (state != null && state.stage != ListenStage.ready) ...[
                const SizedBox(height: 8),
                if (running) LinearProgressIndicator(value: state.fraction),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
                  child: Text(
                    state.line,
                    key: const Key('listen-in-language-line'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: state.stage == ListenStage.failed
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ] else if (lang == null) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
                  child: Text(
                    'Transcribes, translates and speaks the episode, then '
                    'keeps the audio.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
