/// The ⋮ menu every row of works carries. The work kind's shared items
/// come first and are the same on every screen; a screen's own items
/// (Keep, Remove from Queue) follow after a divider, so the menu means
/// the same thing wherever the work appears.
library;

import 'package:flutter/material.dart';

import '../episodes/episode_actions.dart';
import '../transcribe/transcript_so_far.dart';
import 'work_row.dart';

/// [transcript] says where [e]'s transcript stands, so Transcribe reads
/// the same on every screen: "Transcribe again" only over a whole one. [shownAsButtons] names the
/// item values the caller already shows as buttons (the work page's Play
/// next, Download, Translate…): they are left out, so ⋮ holds only what
/// isn't on screen. Filtered by value, never forked.
///
/// [sourceLang] is what the work is in (see [WorkListState.sourceLangOf]):
/// with [transcript] it decides [offersEnglishTranslate].
List<PopupMenuEntry<String>> workMenuItems(
  EpisodeActions actions,
  WorkEntry e, {
  List<PopupMenuEntry<String>> extras = const [],
  TranscriptStage transcript = TranscriptStage.none,
  String? sourceLang,
  Set<String> shownAsButtons = const {},
}) {
  final core = [
    for (final i in actions.sharedMenuItems(e,
        transcript: transcript, sourceLang: sourceLang))
      if (i is! PopupMenuItem<String> || !shownAsButtons.contains(i.value)) i,
  ];
  return [
    ...core,
    if (core.isNotEmpty && extras.isNotEmpty) const PopupMenuDivider(),
    ...extras,
  ];
}
