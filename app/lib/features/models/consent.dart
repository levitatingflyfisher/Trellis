/// THE download consent chokepoint (ADR-0003 law 6): every egress that
/// fetches bytes — a model, an episode's audio — passes through this one
/// dialog, which states what will be downloaded, how big it is, and the
/// metered-data warning, BEFORE anything touches the wire. There is no
/// second door.
library;

import 'package:flutter/material.dart';

/// One line of the consent list: what, and how big (already formatted;
/// honesty about unknown sizes is the caller's sentence to write).
class DownloadItem {
  final String label;
  const DownloadItem(this.label);
}

/// Returns true only on the user's explicit "Download". Everything else —
/// cancel, barrier tap, back — is a no.
Future<bool> confirmDownload(
  BuildContext context, {
  required List<DownloadItem> items,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('consent-dialog'),
      title: const Text('Download?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('• ${item.label}'),
            ),
          const SizedBox(height: 8),
          Text(
            'This uses the internet. On a metered connection it may '
            'use paid data.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('consent-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Not now'),
        ),
        FilledButton(
          key: const Key('consent-accept'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Download'),
        ),
      ],
    ),
  );
  return ok ?? false;
}
