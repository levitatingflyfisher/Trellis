/// What a tap on a link in the reader offers (frozen references): read the
/// copy kept on this device, keep one, or open the live page in the
/// browser. It replaces the reader's plain "Open this link?" question.
library;

import 'package:flutter/material.dart';

import '../models/format.dart' show formatEpochDay;

/// The choice made on [showLinkSheet].
enum LinkChoice { readKept, keep, openBrowser }

/// "Kept on 14 Nov 2026": the day a page was kept, with its year, since a
/// kept page is read long after.
String keptOnLabel(int epochDay) {
  final year = DateTime.fromMillisecondsSinceEpoch(
          epochDay * Duration.millisecondsPerDay,
          isUtc: true)
      .year;
  return 'Kept on ${formatEpochDay(epochDay)} $year';
}

/// The link [href]'s sheet. [keptEpochDay] is the day its page was kept,
/// null when it is not; [canKeep] offers keeping a copy (false on a tier
/// with no fetcher). Null when the sheet is closed without a choice.
Future<LinkChoice?> showLinkSheet(
  BuildContext context, {
  required String href,
  int? keptEpochDay,
  bool canKeep = true,
}) {
  final uri = Uri.tryParse(href);
  final host = uri?.host ?? href;
  return showModalBottomSheet<LinkChoice>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      final theme = Theme.of(context);
      return SafeArea(
        child: Padding(
          key: const Key('link-sheet'),
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(host, style: theme.textTheme.titleLarge),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  href,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              if (keptEpochDay != null)
                ListTile(
                  key: const Key('link-read-kept'),
                  leading: const Icon(Icons.inventory_2_outlined),
                  title: const Text('Read the kept copy'),
                  subtitle: Text(keptOnLabel(keptEpochDay)),
                  onTap: () => Navigator.of(context).pop(LinkChoice.readKept),
                )
              else if (canKeep)
                ListTile(
                  key: const Key('link-keep'),
                  leading: const Icon(Icons.download_outlined),
                  title: const Text('Keep a copy and read it'),
                  subtitle: Text('Trellis gets this page from $host once '
                      'and keeps its text on this device.'),
                  onTap: () => Navigator.of(context).pop(LinkChoice.keep),
                ),
              ListTile(
                key: const Key('link-open-browser'),
                leading: const Icon(Icons.open_in_browser),
                title: const Text('Open in the browser'),
                subtitle: const Text('Your browser will contact this site.'),
                onTap: () =>
                    Navigator.of(context).pop(LinkChoice.openBrowser),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const Key('link-cancel'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
