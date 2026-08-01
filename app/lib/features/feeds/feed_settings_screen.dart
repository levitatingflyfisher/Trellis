import 'package:flutter/material.dart';

import '../../db/database.dart';
import 'feed_rules.dart';

/// One feed's playback settings (P4 mercy #2): a speed override for its
/// episodes, how many seconds of intro/outro to skip, and how much of its
/// downloaded audio to keep on disk ("archive, never forget" — the
/// episode ROWS are never touched here, only whether their audio FILE
/// sticks around). Every field defers to the app's own default when left
/// blank — this screen only ever writes what the reader actually chose.
///
/// Also home to this feed's rules (Campaign 5 Phase 3) — deliberately on
/// THIS screen rather than a separate one: no include/exclude filter
/// screen existed anywhere in this app to share a precedent with, so this
/// campaign shares layout idioms with the closest real thing instead —
/// this screen's own.
class FeedSettingsScreen extends StatefulWidget {
  final AppDatabase db;
  final Feed feed;
  const FeedSettingsScreen({super.key, required this.db, required this.feed});

  @override
  State<FeedSettingsScreen> createState() => _FeedSettingsScreenState();
}

class _FeedSettingsScreenState extends State<FeedSettingsScreen> {
  static const _speeds = [1.0, 1.25, 1.5, 1.75, 2.0];

  double? _speedOverride;
  late final TextEditingController _introController;
  late final TextEditingController _outroController;
  late final TextEditingController _keepLatestController;
  bool? _dspEnabled;

  late List<FeedRule> _rules;
  late final TextEditingController _ruleTextController;
  FeedRuleField _draftField = FeedRuleField.title;
  FeedRuleMatch _draftMatch = FeedRuleMatch.contains;
  FeedRuleAction _draftAction = FeedRuleAction.skip;

  @override
  void initState() {
    super.initState();
    _speedOverride = widget.feed.speedOverride;
    _introController = TextEditingController(
      text: widget.feed.skipIntroSeconds?.toString() ?? '',
    );
    _outroController = TextEditingController(
      text: widget.feed.skipOutroSeconds?.toString() ?? '',
    );
    _keepLatestController = TextEditingController(
        text: widget.feed.keepLatestAudio?.toString() ?? '');
    _rules = decodeFeedRules(widget.feed.rulesJson);
    _ruleTextController = TextEditingController();
    _dspEnabled = widget.feed.dspEnabled;
  }

  @override
  void dispose() {
    _introController.dispose();
    _outroController.dispose();
    _keepLatestController.dispose();
    _ruleTextController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await widget.db.feedsDao.updatePlaybackSettings(
      widget.feed.id,
      speedOverride: _speedOverride,
      skipIntroSeconds: int.tryParse(_introController.text.trim()),
      skipOutroSeconds: int.tryParse(_outroController.text.trim()),
      keepLatestAudio: int.tryParse(_keepLatestController.text.trim()),
      dspEnabled: _dspEnabled,
    );
    await widget.db.feedsDao.setRules(widget.feed.id, encodeFeedRules(_rules));
    if (mounted) Navigator.of(context).pop();
  }

  void _addRule() {
    final text = _ruleTextController.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _rules = [
        ..._rules,
        FeedRule(
            field: _draftField,
            match: _draftMatch,
            text: text,
            action: _draftAction),
      ];
      _ruleTextController.clear();
    });
  }

  void _deleteRule(int index) =>
      setState(() => _rules = [..._rules]..removeAt(index));

  String _fieldLabel(FeedRuleField f) => switch (f) {
        FeedRuleField.title => 'Title',
        FeedRuleField.description => 'Description',
      };

  String _matchLabel(FeedRuleMatch m) => switch (m) {
        FeedRuleMatch.contains => 'contains',
        FeedRuleMatch.notContains => "doesn't contain",
      };

  String _actionLabel(FeedRuleAction a) => switch (a) {
        FeedRuleAction.skip => 'Skip — never enters',
        FeedRuleAction.markReadOnArrival => 'Mark read on arrival',
        FeedRuleAction.autoKeep => 'Auto-keep — straight to library',
      };

  String _speedLabel(double s) =>
      '${s.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '')}×';

  @override
  Widget build(BuildContext context) {
    final feedName = widget.feed.title.isEmpty
        ? widget.feed.url
        : widget.feed.title;
    return Scaffold(
      appBar: AppBar(title: const Text('Playback settings')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              feedName,
              style: Theme.of(context).textTheme.titleMedium,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
            const SizedBox(height: 16),
            Text(
              'Playback speed for this podcast',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                SizedBox(
                  width: 140,
                  height: 48,
                  child: OutlinedButton(
                    key: const Key('feed-settings-speed-default'),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: _speedOverride == null
                          ? Theme.of(context).colorScheme.secondaryContainer
                          : null,
                    ),
                    onPressed: () => setState(() => _speedOverride = null),
                    child: const Text('Use app default'),
                  ),
                ),
                for (final s in _speeds)
                  SizedBox(
                    width: 72,
                    height: 48,
                    child: OutlinedButton(
                      key: Key('feed-settings-speed-$s'),
                      style: OutlinedButton.styleFrom(
                        backgroundColor: _speedOverride == s
                            ? Theme.of(context).colorScheme.secondaryContainer
                            : null,
                      ),
                      onPressed: () => setState(() => _speedOverride = s),
                      child: Text(_speedLabel(s)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              'Skip the first this many seconds',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('feed-settings-skip-intro'),
              controller: _introController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                hintText: 'e.g. 15 — leave blank to play from the start',
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Stop this many seconds before the end',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('feed-settings-skip-outro'),
              controller: _outroController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                hintText: 'e.g. 30 — leave blank to play to the true end',
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Keep the latest this many episodes\' downloaded audio',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('feed-settings-keep-latest-audio'),
              controller: _keepLatestController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                hintText: 'e.g. 5 — leave blank to keep every episode\'s audio',
              ),
            ),
            const SizedBox(height: 24),
            _DspSettingsSection(
              value: _dspEnabled,
              onChanged: (v) => setState(() => _dspEnabled = v),
            ),
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 16),
            Text('Rules', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
                'Checked in order against new episodes as they arrive — '
                'the first match decides; no match means "enter as normal".',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            for (var i = 0; i < _rules.length; i++) _ruleTile(i, _rules[i]),
            if (_rules.isNotEmpty) const SizedBox(height: 16),
            Text('Field', style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final f in FeedRuleField.values)
                  ChoiceChip(
                    key: Key('rule-field-${f.name}'),
                    label: Text(_fieldLabel(f)),
                    selected: _draftField == f,
                    onSelected: (_) => setState(() => _draftField = f),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text('Match', style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final m in FeedRuleMatch.values)
                  ChoiceChip(
                    key: Key('rule-match-${m.name}'),
                    label: Text(_matchLabel(m)),
                    selected: _draftMatch == m,
                    onSelected: (_) => setState(() => _draftMatch = m),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('rule-text'),
              controller: _ruleTextController,
              decoration:
                  const InputDecoration(hintText: 'Text to match, e.g. sponsored'),
            ),
            const SizedBox(height: 16),
            Text('Action', style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final a in FeedRuleAction.values)
                  ChoiceChip(
                    key: Key('rule-action-${a.name}'),
                    label: Text(_actionLabel(a)),
                    selected: _draftAction == a,
                    onSelected: (_) => setState(() => _draftAction = a),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 48,
              child: OutlinedButton(
                key: const Key('rule-add'),
                onPressed: _addRule,
                child: const Text('Add rule'),
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              height: 48,
              child: FilledButton(
                key: const Key('feed-settings-save'),
                onPressed: _save,
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ruleTile(int index, FeedRule rule) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
                '${_fieldLabel(rule.field)} ${_matchLabel(rule.match)} '
                '"${rule.text}" — ${_actionLabel(rule.action)}',
                overflow: TextOverflow.ellipsis,
                maxLines: 2),
          ),
          IconButton(
            key: Key('rule-delete-$index'),
            tooltip: 'Delete this rule',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _deleteRule(index),
          ),
        ],
      ),
    );
  }
}

/// The offline DSP preprocess's per-feed opt-in (Campaign 6, ADR-0012) —
/// a self-contained subtree (own state read from [value], own Keys
/// namespace) so it composes cleanly with whatever else lands on this
/// same screen. Same tri-state law as the speed override above: null
/// defers to the household default (set elsewhere), true/false is an
/// explicit override either way.
class _DspSettingsSection extends StatelessWidget {
  final bool? value;
  final ValueChanged<bool?> onChanged;
  const _DspSettingsSection({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Trim silence & even out volume (downloaded episodes)',
          style: theme.textTheme.bodyLarge,
        ),
        const SizedBox(height: 4),
        Text(
          'Processed on this device when an episode downloads. '
          'Streaming playback is never touched.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            SizedBox(
              width: 140,
              height: 48,
              child: OutlinedButton(
                key: const Key('feed-settings-dsp-default'),
                style: OutlinedButton.styleFrom(
                  backgroundColor: value == null
                      ? theme.colorScheme.secondaryContainer
                      : null,
                ),
                onPressed: () => onChanged(null),
                child: const Text('Use app default'),
              ),
            ),
            SizedBox(
              width: 88,
              height: 48,
              child: OutlinedButton(
                key: const Key('feed-settings-dsp-on'),
                style: OutlinedButton.styleFrom(
                  backgroundColor: value == true
                      ? theme.colorScheme.secondaryContainer
                      : null,
                ),
                onPressed: () => onChanged(true),
                child: const Text('On'),
              ),
            ),
            SizedBox(
              width: 88,
              height: 48,
              child: OutlinedButton(
                key: const Key('feed-settings-dsp-off'),
                style: OutlinedButton.styleFrom(
                  backgroundColor: value == false
                      ? theme.colorScheme.secondaryContainer
                      : null,
                ),
                onPressed: () => onChanged(false),
                child: const Text('Off'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
