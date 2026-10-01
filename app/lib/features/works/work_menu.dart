/// The ⋮ menu every row of works carries. The work kind's shared items
/// come first and are the same on every screen; a screen's own items
/// (Keep, Remove from Queue) follow after a divider, so the menu means
/// the same thing wherever the work appears.
library;

import 'package:flutter/material.dart';

import '../episodes/episode_actions.dart';
import 'work_row.dart';

/// [transcribed] says whether [e] has a transcript, so Transcribe reads
/// "Transcribe again" on every screen alike. [shownAsButtons] names the
/// item values the caller already shows as buttons (the work page's Play
/// next, Download, Translate…): they are left out, so ⋮ holds only what
/// isn't on screen. Filtered by value, never forked.
List<PopupMenuEntry<String>> workMenuItems(
  EpisodeActions actions,
  WorkEntry e, {
  List<PopupMenuEntry<String>> extras = const [],
  bool transcribed = false,
  Set<String> shownAsButtons = const {},
}) {
  final core = [
    for (final i in actions.sharedMenuItems(e, transcribed: transcribed))
      if (i is! PopupMenuItem<String> || !shownAsButtons.contains(i.value)) i,
  ];
  return [
    ...core,
    if (core.isNotEmpty && extras.isNotEmpty) const PopupMenuDivider(),
    ...extras,
  ];
}
