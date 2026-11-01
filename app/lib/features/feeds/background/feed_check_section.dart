/// The feed-check switches as one section, shown in two places: under
/// Models & storage, and behind Subscriptions' "Wi-Fi and data".
library;

import 'package:flutter/material.dart';

import '../../listen/make_ahead.dart'
    show makeAheadDefaultLimitGb, makeAheadLimitChoicesGb;
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
              title: const Text('Refresh feeds on Wi-Fi only'),
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
              title: const Text('Download on Wi-Fi only'),
              subtitle: const Text(
                  'On mobile data, a download you start waits and begins '
                  'when Wi-Fi is back. “Download now” on its row starts '
                  'that one anyway.'),
              value: s.downloadsWifiOnly,
              onChanged: s.setDownloadsWifiOnly,
            ),
            // ADR-0021: one setting, a few plain choices.
            ListTile(
              title: const Text('Room for episodes made ahead'),
              subtitle: const Text(
                  'When it’s full, the oldest goes first, played before '
                  'unplayed. Audio you made by tapping or marked Keep stays.'),
              trailing: DropdownButton<int>(
                key: const Key('make-ahead-limit'),
                value: s.makeAheadLimitGb,
                onChanged: (v) => s.setMakeAheadLimitGb(v ?? makeAheadDefaultLimitGb),
                items: [
                  for (final gb in makeAheadLimitChoicesGb)
                    DropdownMenuItem<int>(
                      key: Key('make-ahead-limit-$gb'),
                      value: gb,
                      child: Text('$gb GB'),
                    ),
                ],
              ),
            ),
            // 1.6.0, user: "Play for download then play", "stream vs play
            // vs download ... more explicit". Stream until chosen, so Play
            // starts at once as before.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('When an episode isn’t downloaded, Play will',
                  style: theme.textTheme.titleSmall),
            ),
            RadioGroup<bool>(
              key: const Key('play-choice'),
              groupValue: s.downloadFirst,
              onChanged: (v) => s.setDownloadFirst(v ?? false),
              child: const Column(
                children: [
                  RadioListTile<bool>(
                    key: Key('play-stream'),
                    value: false,
                    title: Text('Stream'),
                    subtitle: Text('Starts at once, over the network.'),
                  ),
                  RadioListTile<bool>(
                    key: Key('play-download-first'),
                    value: true,
                    title: Text('Download, then play'),
                    subtitle: Text('Fetches it first. With “Download on '
                        'Wi-Fi only” on, on mobile data it waits for Wi-Fi.'),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
