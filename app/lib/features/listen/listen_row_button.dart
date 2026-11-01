/// The second button on an episode's row: the episode in the learning
/// language. Play beside it stays what it was and plays at once; this one
/// says which of three things it is: not made yet (a tap makes it), being
/// made (how far, and a tap offers Stop), or ready (a tap plays it).
///
/// It holds no state. Everything it shows is read from the one
/// [ListenJobs], so it is right again the moment a row is rebuilt.
library;

import 'package:flutter/material.dart';

import '../../db/database.dart';
import '../reader/translation/language_names.dart';
import 'listen_jobs.dart';

class ListenRowButton extends StatelessWidget {
  const ListenRowButton({
    super.key,
    required this.jobs,
    required this.work,
    required this.episode,
    this.feedLang,
  });

  final ListenJobs jobs;
  final Work work;
  final Episode episode;

  /// The show's language, for an episode that names none.
  final String? feedLang;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: jobs,
      builder: (context, _) {
        final offer = jobs.offerFor(work, episode, feedLang: feedLang);
        // Absent, not dead: a button that could only fail is worse than
        // none, and nothing here takes room in the row.
        if (offer == null) return const SizedBox.shrink();
        final lang = offer.lang;
        // The language by name where there is room for it, by its code on
        // a narrow phone, where the name would push the row's buttons
        // onto a second line.
        final wide = MediaQuery.sizeOf(context).width >= 400;
        final name = lang == null
            ? null
            : wide
                ? languageDisplayName(lang)
                : lang.toUpperCase();
        final fraction = offer.fraction;
        final words = name == null || fraction == null
            ? name
            : '$name ${(fraction * 100).round()}%';
        final Widget icon = offer.making
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    value: fraction, strokeWidth: 2.5),
              )
            : Icon(offer.waiting
                ? Icons.hourglass_empty
                : offer.ready
                    ? Icons.play_circle
                    : Icons.translate);
        final style = TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 6),
        );
        void onPressed() =>
            jobs.tap(context, work, episode, feedLang: feedLang);
        final key = Key('listen-${work.id}');
        return Tooltip(
          message: offer.label,
          // A long press on a row belongs to the row (selection, the
          // Queue's drag), not to this hint.
          triggerMode: TooltipTriggerMode.manual,
          // The button says the same sentence itself.
          excludeFromSemantics: true,
          child: words == null
              ? TextButton(
                  key: key,
                  style: style,
                  onPressed: onPressed,
                  child: Semantics(label: offer.label, child: icon),
                )
              : TextButton.icon(
                  key: key,
                  style: style,
                  onPressed: onPressed,
                  icon: icon,
                  label: Text(words, semanticsLabel: offer.label),
                ),
        );
      },
    );
  }
}
