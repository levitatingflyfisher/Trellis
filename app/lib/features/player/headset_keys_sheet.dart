/// The Headphone buttons sheet (1.6.0); see headset_keys.dart for why
/// the settings are per key and not per earbud.
library;

import 'package:flutter/material.dart';

import 'headset_keys.dart';

class HeadsetKeysSheet extends StatefulWidget {
  const HeadsetKeysSheet({super.key, required this.store});
  final HeadsetKeysStore store;

  @override
  State<HeadsetKeysSheet> createState() => _HeadsetKeysSheetState();
}

class _HeadsetKeysSheetState extends State<HeadsetKeysSheet> {
  HeadsetKeys? _keys;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final keys = await widget.store.read();
    if (mounted) setState(() => _keys = keys);
  }

  Future<void> _change(Future<void> Function() write) async {
    await write();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final keys = _keys;
    if (keys == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: ListView(
          key: const Key('headset-keys-sheet'),
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text('Headphone buttons',
                  style: theme.textTheme.titleMedium),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                  'Your headphones turn each tap into a button before the '
                  'phone hears of it. Trellis can’t tell the left earbud '
                  'from the right; if each side should do something '
                  'different, set that in the headphones’ own app.'),
            ),
            ..._group(
              theme,
              group: 'next',
              title: 'Next button',
              hint: 'On most earbuds this is a double tap.',
              value: keys.next,
              onPick: (a) => _change(() => widget.store.setNext(a)),
            ),
            ..._group(
              theme,
              group: 'previous',
              title: 'Previous button',
              hint: 'On most earbuds this is a triple tap.',
              value: keys.previous,
              onPick: (a) => _change(() => widget.store.setPrevious(a)),
            ),
            SwitchListTile(
              key: const Key('headset-count-clicks'),
              title: const Text('Count clicks on a one-button headset'),
              subtitle: const Text(
                  'Two clicks act as Next and three as Previous. Play and '
                  'pause then wait a moment to see if another click '
                  'follows.'),
              value: keys.countClicks,
              onChanged: (on) =>
                  _change(() => widget.store.setCountClicks(on)),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _group(
    ThemeData theme, {
    required String group,
    required String title,
    required String hint,
    required HeadsetAction value,
    required void Function(HeadsetAction) onPick,
  }) =>
      [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(title, style: theme.textTheme.labelLarge),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
          child: Text(hint, style: theme.textTheme.bodySmall),
        ),
        RadioGroup<HeadsetAction>(
          key: Key('headset-$group'),
          groupValue: value,
          onChanged: (a) {
            if (a != null) onPick(a);
          },
          child: Column(children: [
            for (final a in HeadsetAction.values)
              RadioListTile<HeadsetAction>(
                key: Key('headset-$group-${a.name}'),
                value: a,
                title: Text(a.label),
              ),
          ]),
        ),
      ];
}
