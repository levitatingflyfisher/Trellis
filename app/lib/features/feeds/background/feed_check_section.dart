/// The feed-check switches as one section, shown in two places: under
/// Models & storage, and behind Subscriptions' "Wi-Fi and data".
library;

import 'package:flutter/material.dart';

import 'feed_check_settings.dart';

/// "Checking feeds": the device's two background-check switches. New
/// episodes wait in Latest; nothing here ever notifies (ADR-0003). Then
/// "Downloads": whether a download started by hand waits for Wi-Fi, and
/// whether Play downloads an episode before playing it.
class FeedCheckSection extends StatefulWidget {
  const FeedCheckSection({super.key, required this.settings});
  final FeedCheckSettings settings;

  @override
  State<FeedCheckSection> createState() => _FeedCheckSectionState();
}

class _FeedCheckSectionState extends State<FeedCheckSection> {
  @override
  void initState() {
    super.initState();
    widget.settings.load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.settings,
      builder: (context, _) {
        final s = widget.settings;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
              child: Text('Checking feeds', style: theme.textTheme.titleMedium),
            ),
            SwitchListTile(
              key: const Key('feed-check-background'),
              title: const Text('Check feeds in the background'),
              subtitle: const Text(
                  'About every 4 hours, when the battery isn’t low. New '
                  'episodes wait in Latest; you won’t get a notification.'),
              value: s.background,
              onChanged: s.setBackground,
            ),
            SwitchListTile(
              key: const Key('feed-check-wifi-only'),
              title: const Text('Only on Wi-Fi'),
              subtitle: const Text(
                  'Automatic downloads always wait for Wi-Fi.'),
              value: s.wifiOnly,
              onChanged: s.background ? s.setWifiOnly : null,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('Downloads', style: theme.textTheme.titleMedium),
            ),
            // 1.6.0, user: "download on WiFi or not" was missing. Off
            // until chosen, so a tapped download starts at once as before.
            SwitchListTile(
              key: const Key('downloads-wifi-only'),
              title: const Text('Download only on Wi-Fi'),
              subtitle: const Text(
                  'On mobile data, a download you start waits and begins '
                  'when Wi-Fi is back. “Download now” on its row starts '
                  'that one anyway.'),
              value: s.downloadsWifiOnly,
              onChanged: s.setDownloadsWifiOnly,
            ),
            // 1.6.0, user: "Play for download then play". Off until
            // chosen, so Play streams at once as before.
            SwitchListTile(
              key: const Key('play-download-first'),
              title: const Text('Download first, then play'),
              subtitle: const Text(
                  'Play on an episode that isn’t downloaded fetches it, '
                  'then plays it. Off, it streams at once. With “Download '
                  'only on Wi-Fi” on, on mobile data it waits for Wi-Fi.'),
              value: s.downloadFirst,
              onChanged: s.setDownloadFirst,
            ),
          ],
        );
      },
    );
  }
}
