import 'package:flutter/material.dart';

/// One plain line under a tab's title that says what the screen is for
/// (owner, 12 Nov: "what is library if 'latest' has all, text, and
/// audio?"). Quiet on purpose: it is read once and then known.
class PurposeLine extends StatelessWidget {
  final String text;

  /// The line's own key, on its [Text].
  final Key textKey;
  const PurposeLine(this.text, {super.key, required this.textKey});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Text(
          text,
          key: textKey,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}
