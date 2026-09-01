import 'package:flutter/material.dart';

/// An inline refusal or failure under a field: urgency colour, the error
/// icon and the sentence in weight, never colour alone (the fleet colour
/// language; audit dfh-03, dfh-04). [textKey] stays on the sentence, so a
/// test can read it as before.
class ErrorLine extends StatelessWidget {
  const ErrorLine(this.message, {super.key, this.textKey});

  final String message;
  final Key? textKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.error;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline, size: 20, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(message,
              key: textKey,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: color, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}
