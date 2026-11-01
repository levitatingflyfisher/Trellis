import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../models/consent.dart';
import 'auto_download.dart';
import 'feed_rules.dart';
import '../player/speed_control.dart';
import '../shared/capped_body.dart';
import '../shared/preset_chips.dart';

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
/// Seconds to skip at a show's start or before its end; null is Off.
const List<int?> skipSecondsPresets = [null, 5, 10, 15, 30, 45, 60];

/// How many of the newest episodes keep their downloaded audio; null keeps
/// every one.
const List<int?> keepLatestPresets = [null, 1, 3, 5, 10, 25];

String _offKey(int? v) => v == null ? 'off' : '$v';
String _secondsLabel(int? v) => v == null ? 'Off' : '$v s';

class FeedSettingsScreen extends StatefulWidget {
  final AppDatabase db;
  final Feed feed;

  /// Whether this device can run an auto-download pass; the switch is
  /// offered only then (ADR-0018).
  final bool offerAutoDownload;
  const FeedSettingsScreen(
      {super.key,
      required this.db,
      required this.feed,
      this.offerAutoDownload = false});

  @override
  State<FeedSettingsScreen> createState() => _FeedSettingsScreenState();
}

class _FeedSettingsScreenState extends State<FeedSettingsScreen> {

  double? _speedOverride;
  int? _skipIntro;
  int? _skipOutro;
  int? _keepLatest;
  bool? _dspEnabled;
  late bool _autoDownload = widget.feed.autoDownload;

  late List<FeedRule> _rules;
  late final TextEditingController _ruleTextController;
  FeedRuleField _draftField = FeedRuleField.title;
  FeedRuleMatch _draftMatch = FeedRuleMatch.contains;
  FeedRuleAction _draftAction = FeedRuleAction.skip;

  @override
  void initState() {
    super.initState();
    _speedOverride = widget.feed.speedOverride;
    _skipIntro = widget.feed.skipIntroSeconds;
    _skipOutro = widget.feed.skipOutroSeconds;
    _keepLatest = widget.feed.keepLatestAudio;
    _rules = decodeFeedRules(widget.feed.rulesJson);
    _ruleTextController = TextEditingController();
    _dspEnabled = widget.feed.dspEnabled;
  }

  @override
  void dispose() {
    _ruleTextController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await widget.db.feedsDao.updatePlaybackSettings(
      widget.feed.id,
      speedOverride: _speedOverride,
      skipIntroSeconds: _skipIntro,
      skipOutroSeconds: _skipOutro,
      keepLatestAudio: _keepLatest,
      dspEnabled: _dspEnabled,
    );
    await widget.db.feedsDao.setRules(widget.feed.id, encodeFeedRules(_rules));
    if (_autoDownload != widget.feed.autoDownload) {
      await setFeedAutoDownload(widget.db, widget.feed.id, _autoDownload);
    }
    if (mounted) Navigator.of(context).pop();
  }

  /// Turning it on is consent to downloads nobody taps for, so it passes
  /// the same dialog a tapped Download does (ADR-0003 law 6).
  Future<void> _toggleAutoDownload(bool on) async {
    if (on) {
      final ok = await confirmDownload(context, items: const [
        DownloadItem('New episodes of this show as they arrive: up to '
            '$autoDownloadPerFeedCap each time feeds are checked, only on '
            'Wi-Fi'),
      ]);
      if (!ok) return;
    }
    if (mounted) setState(() => _autoDownload = on);
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
        FeedRuleMatch.notContains => "doesn’t contain",
      };

  String _actionLabel(FeedRuleAction a) => switch (a) {
        FeedRuleAction.skip => 'Skip: never enters',
        FeedRuleAction.markReadOnArrival => 'Mark read on arrival',
        FeedRuleAction.autoKeep => 'Auto-keep: straight to the library',
      };

  @override
  Widget build(BuildContext context) {
    final feedName = widget.feed.title.isEmpty
        ? widget.feed.url
        : widget.feed.title;
    return Scaffold(
      appBar: AppBar(title: const Text('Playback settings')),
      body: CappedBody(child: SingleChildScrollView(
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
            PresetChips<double?>(
              label: 'Speed',
              keyPrefix: 'feed-settings-speed',
              options: const [null, ...speedPresets],
              selected: _speedOverride,
              keyOf: (s) => s == null ? 'default' : '$s',
              labelOf: (s) => s == null ? 'App default' : speedLabel(s),
              onSelected: (s) => setState(() => _speedOverride = s),
              // The same swipe control as the player, for anything
              // between the presets.
              trailing: SpeedControl(
                key: const Key('feed-settings-speed-wheel'),
                speed: _speedOverride ?? 1.0,
                onChanged: (s) => setState(() => _speedOverride = s),
              ),
            ),
            PresetChips<int?>(
              label: 'Skip the start',
              keyPrefix: 'feed-settings-skip-intro',
              options: skipSecondsPresets,
              selected: _skipIntro,
              keyOf: _offKey,
              labelOf: _secondsLabel,
              onSelected: (v) => setState(() => _skipIntro = v),
            ),
            PresetChips<int?>(
              label: 'Stop before the end',
              keyPrefix: 'feed-settings-skip-outro',
              options: skipSecondsPresets,
              selected: _skipOutro,
              keyOf: _offKey,
              labelOf: _secondsLabel,
              onSelected: (v) => setState(() => _skipOutro = v),
            ),
            PresetChips<int?>(
              label: 'Keep downloaded audio of the newest',
              keyPrefix: 'feed-settings-keep-latest-audio',
              options: keepLatestPresets,
              selected: _keepLatest,
              keyOf: (v) => v == null ? 'all' : '$v',
              labelOf: (v) => v == null ? 'All' : '$v',
              onSelected: (v) => setState(() => _keepLatest = v),
            ),
            PresetChips<bool?>(
              label: 'Trim silence & even out volume',
              keyPrefix: 'feed-settings-dsp',
              options: const [null, true, false],
              selected: _dspEnabled,
              keyOf: (v) => switch (v) {
                null => 'default',
                true => 'on',
                false => 'off',
              },
              labelOf: (v) => switch (v) {
                null => 'App default',
                true => 'On',
                false => 'Off',
              },
              onSelected: (v) => setState(() => _dspEnabled = v),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'Done on this device when an episode downloads. Streaming '
                'is never changed.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (widget.offerAutoDownload) ...[
              const SizedBox(height: 8),
              SwitchListTile(
                key: const Key('feed-settings-auto-download'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Download new episodes'),
                subtitle: const Text(
                    'The newest $autoDownloadPerFeedCap from each check, on '
                    'Wi-Fi only. They show in Jobs while they download.'),
                value: _autoDownload,
                onChanged: _toggleAutoDownload,
              ),
            ],
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 16),
            Text('Rules', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
                'Checked in order against new episodes as they arrive: '
                'the first match decides; no match means “enter as normal”.',
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
      )),
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
                '“${rule.text}”: ${_actionLabel(rule.action)}',
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
