/// One setting chosen from a few preset values, as a row of chips
/// (owner, 12 Nov: no free text box where the value is a number from a
/// small range). The chips wrap, so the row holds at any text size.
library;

import 'package:flutter/material.dart';

/// A label over a wrapping row of [ChoiceChip]s, one per entry of
/// [options], each keyed `$keyPrefix-${keyOf(value)}`. A [selected] value
/// that is not among [options] (one typed before the chips existed) gets
/// a chip of its own, so nothing saved is lost or hidden.
class PresetChips<T> extends StatelessWidget {
  const PresetChips({
    super.key,
    required this.label,
    required this.keyPrefix,
    required this.options,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
    this.keyOf,
    this.trailing,
  });

  final String label;
  final String keyPrefix;
  final List<T> options;
  final T selected;
  final String Function(T value) labelOf;
  final String Function(T value)? keyOf;
  final ValueChanged<T> onSelected;

  /// One more control at the end of the row (the speed wheel).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final values = options.contains(selected)
        ? options
        : [...options, selected];
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: theme.textTheme.bodyLarge),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final v in values)
                ChoiceChip(
                  key: Key('$keyPrefix-${(keyOf ?? _plainKey)(v)}'),
                  label: Text(labelOf(v)),
                  selected: v == selected,
                  showCheckmark: false,
                  onSelected: (_) => onSelected(v),
                ),
              ?trailing,
            ],
          ),
        ],
      ),
    );
  }

  static String _plainKey(Object? v) => '$v';
}
