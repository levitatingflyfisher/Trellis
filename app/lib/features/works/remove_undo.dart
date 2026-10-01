/// Remove, with the fleet's lasting Undo (delete ruling: a deliberate
/// delete doesn't ask, it offers an Undo that never times out). One home
/// for the Library row's Remove and the work page's, so both mean, show
/// and do the same thing.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../db/database.dart';

/// Offers Undo for removing [work] on [messenger], the app's own (it
/// outlives the screen that asked, so a page can close and the Undo stays
/// on the screen beneath). Nothing changes while the offer stands: the
/// removal runs once, when it closes without Undo (Dismiss, or another
/// offer taking its place). A feed item only leaves the Library, since
/// Latest keeps it (ADR-0019 §1); anything else is deleted, an
/// audiobook's copied files through [deleteAudiobookFiles]. A process
/// killed while the offer stands removes nothing.
///
/// Completes with true once removed, false when undone.
Future<bool> removeWithUndo(
  ScaffoldMessengerState messenger, {
  required AppDatabase db,
  required Work work,
  required bool fromFeed,
  void Function(int workId)? deleteAudiobookFiles,
}) {
  final outcome = Completer<bool>();
  final message = fromFeed
      ? "Removed '${work.title}' from Library"
      : "Removed '${work.title}'";
  messenger.clearSnackBars();
  final bar = messenger.showSnackBar(
    SnackBar(
      key: Key('remove-undo-${work.id}'),
      // Never times out: an Undo that vanishes while you are still reading
      // it strands you. It goes on Undo, on Dismiss, or when another offer
      // replaces it.
      persist: true,
      content: Builder(
        builder: (context) => Row(
          children: [
            Expanded(child: Text(message)),
            IconButton(
              tooltip: 'Dismiss',
              color: Theme.of(context).colorScheme.onInverseSurface,
              icon: const Icon(Icons.close),
              onPressed: () => messenger.hideCurrentSnackBar(
                reason: SnackBarClosedReason.dismiss,
              ),
            ),
          ],
        ),
      ),
      action: SnackBarAction(label: 'Undo', onPressed: () {}),
    ),
  );
  unawaited(
    bar.closed.then((reason) async {
      if (reason == SnackBarClosedReason.action) {
        outcome.complete(false);
        return;
      }
      final deleted = await db.spineDao.removeFromLibrary(work.id);
      if (deleted && work.kind == 'audiobook') {
        deleteAudiobookFiles?.call(work.id);
      }
      outcome.complete(true);
    }),
  );
  return outcome.future;
}
