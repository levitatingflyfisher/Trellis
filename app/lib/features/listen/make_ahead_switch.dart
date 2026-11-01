/// A show's page's make-ahead switch, and the plain line for the Jobs
/// page. Both only read [ListenJobs], so they are right the moment
/// anything changes.
library;

import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../reader/translation/language_names.dart';
import 'listen_jobs.dart';
import 'make_ahead.dart' show makeAheadPerShow;

class MakeAheadTile extends StatelessWidget {
  const MakeAheadTile({super.key, required this.jobs, required this.feed});

  final ListenJobs jobs;
  final Feed feed;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: jobs,
      builder: (context, _) {
        final offer = jobs.aheadOfferFor(feed);
        // Absent, not dead: a switch that could only fail is worse than none.
        if (offer == null) return const SizedBox.shrink();
        final lang = offer.lang;
        final line = offer.line;
        return SwitchListTile(
          key: const Key('make-ahead-switch'),
          contentPadding: EdgeInsets.zero,
          title: Text(lang == null
              ? 'Make new episodes ahead'
              : 'Make new episodes in ${languageDisplayName(lang)} ahead'),
          subtitle: Text([
            'On Wi-Fi while charging, when Trellis is open or already '
                'working. Up to $makeAheadPerShow at a time.',
            ?line,
          ].join(' ')),
          value: offer.on,
          onChanged: (on) => jobs.setMakeAhead(context, feed, on),
        );
      },
    );
  }
}

class MakeAheadLine extends StatelessWidget {
  const MakeAheadLine({super.key, required this.jobs});

  final ListenJobs jobs;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: jobs,
      builder: (context, _) {
        final line = jobs.aheadLine;
        if (line == null) return const SizedBox.shrink();
        return Padding(
          key: const Key('make-ahead-line'),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(line, style: Theme.of(context).textTheme.bodySmall),
        );
      },
    );
  }
}
