/// Before a link leaves the app, the person is told where it goes and
/// asked (1.5.4, for show notes; since 1.6.2 for links in the reader too).
/// One sheet for both, so a link is the same thing wherever it is met.
library;

import 'package:flutter/material.dart';

/// Asks whether to open [href], then hands it to [open]. Only web and
/// email addresses ever leave the app; anything else is ignored.
Future<void> confirmAndOpenLink(BuildContext context, String href,
    Future<void> Function(Uri uri) open) async {
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    // Checked again here, not only at storage: whatever HTML a later
    // caller hands this view, only the web and email leave the app.
    final scheme = uri.scheme.toLowerCase();
    final web = (scheme == 'http' || scheme == 'https') && uri.host.isNotEmpty;
    if (!web && scheme != 'mailto') return;
    final host = uri.scheme == 'mailto' ? uri.path : uri.host;
    final yes = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          child: Padding(
            key: const Key('link-confirm'),
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  uri.scheme == 'mailto'
                      ? 'Write an email?'
                      : 'Open this link?',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Text(host, style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  href,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Text(
                  uri.scheme == 'mailto'
                      ? 'It opens in your email app.'
                      : 'It opens in your browser, which will contact this '
                            'site.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      key: const Key('link-cancel'),
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const Key('link-open'),
                      onPressed: () => Navigator.of(context).pop(true),
                      child: Text(
                        uri.scheme == 'mailto' ? 'Open email' : 'Open',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    if (yes == true) await open(uri);
}
