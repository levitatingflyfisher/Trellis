/// "On this phone" (boards 0127 and 0131, owner: "it doesn't have a
/// screen or filter to show just downloaded episodes I can see (to reduce
/// memory)"): the episodes whose audio is on the phone, made episodes in
/// any language included, each with its size, and the way to take the
/// audio off one or several and keep the rest.
///
/// Only episodes are listed. A book or a text is left out: its text is
/// small, and deleting it would lose the book itself, not a copy that can
/// be fetched again.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:openhearth_design/openhearth_design.dart';

import '../../db/database.dart';
import '../../services/device_services.dart';
import '../episodes/episode_actions.dart';
import '../listen/listen.dart' show isSpokenGuid;
import '../models/format.dart';
import '../reader/translation/language_names.dart';
import 'work_storage.dart';

/// One episode whose audio is on this phone, and what it takes there:
/// the downloaded or made audio, and a decoded copy left by transcribing.
typedef OnPhoneEntry = ({RiverEntry entry, int bytes});

/// Every episode of [profileId]'s whose audio is on this phone, biggest
/// first: the view is for freeing space. Audio left by an episode that
/// no longer exists stays with Storage by item and Clear all.
Future<List<OnPhoneEntry>> loadOnPhone(AppDatabase db,
    {required DeviceServices services, required int profileId}) async {
  final audio = audioOnDisk(services);
  // A version's audio counts under its episode (1.6.18: they live
  // together); an episode whose only audio is a version's is listed too.
  final byEpisode = <int, int>{};
  for (final MapEntry(key: id, value: bytes) in audio.entries) {
    final v = await db.versionsDao.versionOf(id);
    final at = v?.originalId ?? id;
    byEpisode[at] = (byEpisode[at] ?? 0) + bytes;
  }
  final out = <OnPhoneEntry>[];
  for (final MapEntry(key: id, value: bytes) in byEpisode.entries) {
    final entry = await db.feedsDao.riverEntryOf(id);
    if (entry == null || entry.work.profileId != profileId) continue;
    if (entry.episode.enclosureUrl == null) continue;
    final pcm = services.pcmFileFor(id);
    out.add((
      entry: entry,
      bytes: bytes + (pcm.existsSync() ? pcm.lengthSync() : 0),
    ));
  }
  out.sort((a, b) {
    final by = b.bytes.compareTo(a.bytes);
    return by != 0 ? by : b.entry.work.id.compareTo(a.entry.work.id);
  });
  return out;
}

/// The line at the top of the view.
String onPhoneTotalLine(List<OnPhoneEntry> entries) {
  if (entries.isEmpty) return 'No episode audio is on this phone.';
  final n = entries.length;
  final bytes = entries.fold(0, (a, e) => a + e.bytes);
  return '${n == 1 ? '1 episode' : '$n episodes'}, '
      '${formatBytes(bytes)} in all.';
}

/// Whether [e] is a made episode whose original is gone (made before
/// 1.6.18), whose audio comes back by the tap that made it rather than by
/// a download.
bool isMadeEpisode(Episode e) => isSpokenGuid(e.guid);

/// The languages whose made audio is on the phone for [workIds]: what
/// Remove audio takes with them.
Future<List<String>> madeAudioLangsOf(AppDatabase db, DeviceServices services,
    Iterable<int> workIds) async {
  final langs = <String>{};
  for (final (lang, _) in await _madeAudioOf(db, services, workIds)) {
    langs.add(lang);
  }
  return langs.toList();
}

Future<List<(String, File)>> _madeAudioOf(AppDatabase db,
    DeviceServices services, Iterable<int> workIds) async {
  final out = <(String, File)>[];
  for (final id in workIds) {
    for (final v in await db.versionsDao.versionsOf(id)) {
      final url = (await db.spineDao.workById(v.workId))?.sourceUrl;
      final f = url == null ? null : services.audioFileFor(v.workId, url);
      if (f != null && f.existsSync()) out.add((v.lang, f));
    }
  }
  return out;
}

/// Asks once, plain about what goes, what stays and how it comes back.
/// Audio is not kept in Recently deleted, so the space comes back at once
/// and the confirm says so.
///
/// [kept] are chosen episodes that keep their audio (playing, transcribing
/// or processing): their space is not promised, and they are named.
Future<bool> confirmRemoveAudio(
    BuildContext context, List<OnPhoneEntry> chosen,
    {int kept = 0, List<String> madeLangs = const []}) {
  final n = chosen.length;
  final bytes = chosen.fold(0, (a, e) => a + e.bytes);
  final made = chosen.where((e) => isMadeEpisode(e.entry.episode)).length;
  final fetched = n - made;
  final message = [
    'Frees ${formatBytes(bytes)} now.',
    n == 1
        ? 'The episode stays, with its transcript, your place and your '
            'study cards.'
        : 'The episodes stay, each with its transcript, your place and '
            'your study cards.',
    'Audio isn’t kept in Recently deleted.',
    if (kept == 1)
      'One more you chose is playing, being transcribed or processed, '
          'and keeps its audio.',
    if (kept > 1)
      '$kept more you chose are playing, being transcribed or processed, '
          'and keep their audio.',
    if (fetched == 1 && n == 1) 'You can download it again.',
    if (fetched > 0 && n > 1) 'A downloaded episode can be downloaded again.',
    if (made > 0)
      'A made episode is made again by the same Listen tap on its '
          'original.',
    if (madeLangs.isNotEmpty)
      '${n == 1 ? 'Its' : 'Their'} ${_names(madeLangs)} audio goes too; the '
          'same Listen tap makes it again.',
  ].join(' ');
  return showOhConfirm(
    context,
    title: n == 1
        ? 'Remove this episode’s audio?'
        : 'Remove the audio of $n episodes?',
    message: message,
    confirmLabel: 'Remove audio',
    cancelLabel: 'Keep',
    destructive: true,
  );
}

/// Takes the audio of [chosen] off the phone, with any decoded copy, and
/// says what happened. An episode playing, transcribing or being
/// processed keeps its audio, the rule every Remove download follows.
Future<String> removeOnPhoneAudio(
  List<OnPhoneEntry> chosen, {
  required AppDatabase db,
  required DeviceServices services,
  required EpisodeActions actions,
}) async {
  final r = await actions.removeDownloads([
    for (final e in chosen) (work: e.entry.work, episode: e.entry.episode),
  ]);
  // Their made languages' audio goes with them; the versions' text stays.
  // One playing keeps its audio, the rule every Remove download follows.
  final busy = await actions.busyWorkIds();
  for (final e in chosen) {
    final id = e.entry.work.id;
    if (busy.contains(id)) continue;
    for (final v in await db.versionsDao.versionsOf(id)) {
      if (busy.contains(v.workId)) continue;
      final url = (await db.spineDao.workById(v.workId))?.sourceUrl;
      final f = url == null ? null : services.audioFileFor(v.workId, url);
      if (f != null && f.existsSync()) f.deleteSync();
    }
  }
  if (r.kept == 0) {
    // A file fetched under an older address has another name than the
    // one removeDownloads looks for; nothing is using it.
    for (final e in chosen) {
      deleteAudioFilesOf(services, e.entry.work.id);
    }
  }
  final left = audioOnDisk(services);
  var removed = 0;
  for (final e in chosen) {
    final id = e.entry.work.id;
    if (left.containsKey(id)) continue;
    removed++;
    final pcm = services.pcmFileFor(id);
    if (pcm.existsSync() && !await isTranscribing(db, id)) pcm.deleteSync();
  }
  return [
    if (removed == 1) 'Removed the audio of 1 episode.',
    if (removed > 1) 'Removed the audio of $removed episodes.',
    if (r.kept == 1)
      'The episode playing, transcribing or processing keeps its audio.',
    if (r.kept > 1)
      '${r.kept} episodes playing, transcribing or processing keep their '
          'audio.',
    if (removed == 0 && r.kept == 0) 'Nothing needed removing.',
  ].join(' ');
}

String _names(List<String> langs) {
  final names = [for (final l in langs) languageDisplayName(l)];
  if (names.length == 1) return names.single;
  return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}
