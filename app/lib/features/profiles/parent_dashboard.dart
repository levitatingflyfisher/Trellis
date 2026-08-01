import 'package:flutter/material.dart';

import '../../db/database.dart';
import 'parent_pin.dart';
import 'pin_dialogs.dart';

/// The parent dashboard (P5): a calm per-profile card of what each reader
/// has BUILT — lifetime totals only (ADR-0003 law 5). Design laws:
///
/// - Positive framing: a stat appears only once it exists; a brand-new
///   reader gets "Just getting started.", never a wall of zeros. Nothing
///   here can express a streak, a gap or a ranking, and the cards are a
///   vertical list — one reader per card, never a contest.
/// - Reaching this screen already passed the PIN chokepoint
///   (requireParentPin in home_flow), so rename/remove — the other
///   PIN-gated operations — live here and inherit the gate.
/// - Pure database reads (lifetimeBuiltOf); works identically on web.
class ParentDashboardScreen extends StatefulWidget {
  final AppDatabase db;
  final ParentPinService pin;
  const ParentDashboardScreen({super.key, required this.db, required this.pin});

  @override
  State<ParentDashboardScreen> createState() => _ParentDashboardScreenState();
}

typedef _Entry = ({Profile profile, LifetimeBuilt built});

class _ParentDashboardScreenState extends State<ParentDashboardScreen> {
  List<_Entry>? _entries;
  bool _pinSet = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final profiles = await widget.db.profilesDao.all();
    final entries = <_Entry>[
      for (final p in profiles)
        (profile: p, built: await widget.db.householdDao.lifetimeBuiltOf(p.id))
    ];
    final pinSet = await widget.pin.isSet;
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _pinSet = pinSet;
    });
  }

  Future<void> _rename(Profile profile) async {
    final name = await showDialog<String>(
        context: context, builder: (_) => _RenameDialog(initial: profile.name));
    if (name == null || name.isEmpty) return;
    await widget.db.householdDao.renameProfile(profile.id, name);
    await _load();
  }

  Future<void> _remove(Profile profile) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text("Remove ${profile.name}'s profile?"),
        content: const Text(
            'Their library, courses, progress and collected words go with '
            "it. This can't be undone."),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialog).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(dialog).pop(true),
              child: const Text('Remove profile')),
        ],
      ),
    );
    if (sure != true) return;
    await widget.db.householdDao.deleteProfileCascade(profile.id);
    await _load();
  }

  Future<void> _pinDialog(
      Future<void> Function(BuildContext, ParentPinService) show) async {
    await show(context, widget.pin);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(title: const Text('Parent dashboard')),
      body: entries == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('What each reader has built.',
                    style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 8),
                for (final e in entries)
                  _ProfileCard(
                      entry: e,
                      onRename: () => _rename(e.profile),
                      onRemove: () => _remove(e.profile)),
                const SizedBox(height: 16),
                _PinSection(
                  pinSet: _pinSet,
                  onSet: () => _pinDialog(showSetPinDialog),
                  onChange: () => _pinDialog(showChangePinDialog),
                  onRemove: () => _pinDialog(showRemovePinDialog),
                ),
              ],
            ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  final _Entry entry;
  final VoidCallback onRename;
  final VoidCallback onRemove;
  const _ProfileCard(
      {required this.entry, required this.onRename, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final built = entry.built;
    final lines = builtLines(built);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(entry.profile.name,
                style: Theme.of(context).textTheme.titleLarge,
                overflow: TextOverflow.ellipsis,
                maxLines: 1),
            const SizedBox(height: 8),
            if (lines.isEmpty)
              Text('Just getting started.',
                  style: Theme.of(context).textTheme.bodyMedium)
            else
              for (final line in lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(line,
                      style: Theme.of(context).textTheme.bodyMedium),
                ),
            const SizedBox(height: 4),
            // Wrap, not Row: two grown buttons at 320dp/2x must stack
            // instead of overflowing (the fleet's accessibility-overflow
            // pattern).
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                    key: Key('rename-${entry.profile.id}'),
                    onPressed: onRename,
                    icon: const Icon(Icons.drive_file_rename_outline),
                    label: const Text('Rename')),
                TextButton.icon(
                    key: Key('remove-${entry.profile.id}'),
                    onPressed: onRemove,
                    icon: const Icon(Icons.person_remove_alt_1_outlined),
                    label: const Text('Remove')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PinSection extends StatelessWidget {
  final bool pinSet;
  final VoidCallback onSet;
  final VoidCallback onChange;
  final VoidCallback onRemove;
  const _PinSection(
      {required this.pinSet,
      required this.onSet,
      required this.onChange,
      required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Household PIN',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
                pinSet
                    ? 'A PIN protects profile changes and this dashboard — '
                        'never reading or studying.'
                    : 'No PIN is set.',
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: pinSet
                  ? [
                      TextButton(
                          onPressed: onChange, child: const Text('Change PIN')),
                      TextButton(
                          onPressed: onRemove, child: const Text('Remove PIN')),
                    ]
                  : [
                      TextButton(
                          onPressed: onSet, child: const Text('Set a PIN')),
                    ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RenameDialog extends StatefulWidget {
  final String initial;
  const _RenameDialog({required this.initial});

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename reader'),
      content: TextField(
        key: const Key('rename-field'),
        controller: _name,
        autofocus: true,
        onSubmitted: (_) => _save(),
        decoration: const InputDecoration(labelText: 'Name'),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

/// The card's stat lines: only what EXISTS (positive framing, ADR-0003
/// law 5). Zero is expressed by saying nothing, never by "0".
List<String> builtLines(LifetimeBuilt built) {
  final minutes = built.listeningMs ~/ 60000;
  return [
    if (built.worksKept > 0)
      _n(built.worksKept, 'work in the library', 'works in the library'),
    if (built.worksFinished > 0)
      _n(built.worksFinished, 'work finished', 'works finished'),
    if (built.cardsMastered > 0)
      _n(built.cardsMastered, 'card mastered', 'cards mastered'),
    if (built.wordsCollected > 0)
      _n(built.wordsCollected, 'word collected', 'words collected'),
    if (minutes > 0) _listening(minutes),
    if (built.currentCourse != null)
      'Current course: ${built.currentCourse!.title} — '
          '${built.currentCourse!.mastered} of ${built.currentCourse!.total} '
          'mastered',
  ];
}

String _n(int n, String singular, String plural) =>
    n == 1 ? '1 $singular' : '$n $plural';

String _listening(int minutes) {
  if (minutes < 60) return _n(minutes, 'minute of listening', 'minutes of listening');
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0
      ? _n(h, 'hour of listening', 'hours of listening')
      : '$h h $m min of listening';
}
