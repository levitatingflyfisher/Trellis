/// What touching a work in a list does, decided once for every list. A
/// row's tap, its Read and its Play all come through here, so a change to
/// what a tap opens is one change, not six.
library;

import 'package:flutter/material.dart';

import '../../db/database.dart' hide Alignment;
import '../episodes/episode_actions.dart';
import '../player/player_controller.dart';
import '../reader/reader_doors.dart';
import 'device_hooks.dart';
import 'work_page.dart';
import 'work_row.dart';

class WorkDoors {
  final AppDatabase db;
  final int profileId;
  final ReaderDoors readerDoors;
  final PlayerController? _player;

  /// The screen's shared row actions, which the work page's own buttons
  /// and ⋮ reuse. Null leaves the page without them.
  final EpisodeActions? actions;

  /// Opens a link from show notes once the reader agreed; null shows
  /// links as plain text.
  final Future<void> Function(Uri uri)? openLink;

  /// The share of an episode's length transcribing takes on this phone,
  /// or null when that isn't known.
  final double? Function() transcribeRate;

  /// [player] when the screen holds its own; otherwise the reader's.
  const WorkDoors({
    required this.db,
    required this.profileId,
    this.readerDoors = const ReaderDoors(),
    PlayerController? player,
    this.actions,
    this.openLink = openExternalLink,
    this.transcribeRate = deviceTranscribeRate,
  }) : _player = player;

  PlayerController? get player => _player ?? readerDoors.player;

  /// Opens the show a feed item came from; null where this screen can't.
  ShowOpener? get openShow => actions?.openShow;

  /// A tap on the row opens the work's page, for every kind: listening,
  /// reading and its notes are all one tap from there. A row's own Play
  /// never comes here. Completes with the removal's outcome when the page
  /// was closed by Remove (see `removeWithUndo`), so a list can hide the
  /// work while Undo stands; null otherwise.
  Future<Future<bool>?> open(
    BuildContext context,
    WorkEntry e, {
    String? showTitle,
  }) async {
    return Navigator.of(context).push(
      MaterialPageRoute<Future<bool>>(
        builder: (_) => WorkPage(doors: this, entry: e, showTitle: showTitle),
      ),
    );
  }

  /// The reader at the saved place (or at [startSegmentIdx]). Opening a
  /// feed item is reading it, so its New marker clears.
  ///
  /// The work page opens it already doing something: [startSpeaking]
  /// reads aloud, [speakTranslation] speaks the work's chosen
  /// translation, [layerLang] shows an `mt` layer, and
  /// [openTranslatePicker] asks which language to translate into.
  Future<void> read(
    BuildContext context,
    WorkEntry e, {
    int? startSegmentIdx,
    bool startSpeaking = false,
    bool speakTranslation = false,
    String? layerLang,
    bool openTranslatePicker = false,
  }) async {
    final work = e.work;
    if (e.episode != null) {
      await db.feedsDao.markRead(
        work.id,
        DateTime.now().millisecondsSinceEpoch,
      );
    }
    final position = await db.spineDao.position(
      profileId: profileId,
      workId: work.id,
    );
    final count = await db.spineDao.segmentCount(work.id);
    if (!context.mounted) return;
    await readerDoors.open(
      context,
      db: db,
      profileId: profileId,
      work: work,
      position: position,
      segmentCount: count,
      startSegmentIdx: startSegmentIdx,
      startSpeaking: startSpeaking,
      speakTranslation: speakTranslation,
      layerLang: layerLang,
      openTranslatePicker: openTranslatePicker,
    );
  }

  /// Whether the row's Read has somewhere to go: a text always does; a
  /// transcript needs the player it follows.
  bool canRead(WorkEntry e) =>
      isTextWork(e.work, e.episode) || readerDoors.canOpenTranscript;

  /// The row's Read button: a text in the reader, a transcribed episode
  /// in its transcript.
  Future<void> readFromRow(BuildContext context, WorkEntry e) =>
      isTextWork(e.work, e.episode)
      ? read(context, e)
      : readerDoors.openTranscript(context, db: db, work: e.work);

  /// The row's Play button.
  Future<void> play(Work work) async {
    final p = player;
    if (p == null) return;
    if (work.kind == 'audiobook') {
      await p.playAudiobook(work);
    } else {
      await p.playWork(work);
    }
  }
}
