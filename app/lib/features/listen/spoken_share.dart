/// Share on a made episode (1.6.x, owner, 10 Nov: "I'd like to make it so
/// it produces an audio file that can be shared, downloaded, cached").
///
/// A made episode's address can never be fetched (`.invalid`), so sharing
/// its link would hand on nothing. Share sends the audio file itself,
/// named by its title, with words that say the voice is machine made.
/// The file carries the same label in its own tag (`spokenAudioComment`).
///
/// A file in a copy of a real person's voice (the host's cloned voice) is
/// shared only when the listener has turned that on in Settings: the
/// owner's standing rule is that this is a separate switch, off by
/// default.
library;

import 'dart:io';

import '../../db/database.dart';
import 'spoken_voice.dart';

/// The device setting: whether Share may send the audio of an episode
/// made in a copy of a real person's voice. Off unless it reads '1'.
const shareClonedVoiceAudioKey = 'share_cloned_voice_audio';

Future<bool> clonedVoiceShareAllowed(AppDatabase db) async =>
    await db.deviceSettingsDao.read(shareClonedVoiceAudioKey) == '1';

/// What Share sends for a made episode: the [audio] file when it may go
/// (null when it is gone from the phone, or when it is in a cloned voice
/// and that switch is off), its [title], and the [text] that goes with
/// it, which says the voice is machine made.
typedef SpokenShare = ({File? audio, String title, String text});

/// The share for [work] when it is a made episode; null for any other.
Future<SpokenShare?> spokenShareOf(
  AppDatabase db,
  Work work,
  Episode episode, {
  required File Function(int workId, String url)? audioFileFor,
}) async {
  final guid = episode.guid;
  if (!guid.startsWith('spoken:')) return null;
  // Null was stored before the kind was: every voice then was a machine
  // voice.
  final kind = VoiceKind.values
          .where((k) => k.name == episode.voiceKind)
          .firstOrNull ??
      VoiceKind.machine;
  final originalId = int.tryParse(guid.split(':')[1]);
  final original =
      originalId == null ? null : await db.feedsDao.episodeOf(originalId);
  final originalLink = original?.enclosureUrl;
  final text = [
    '“${work.title}”, spoken by ${spokenVoicePhrase(kind)}. The words were '
        'translated by machine, so they can be wrong in places.',
    if (originalLink != null) 'The original: $originalLink',
  ].join('\n');

  final url = episode.enclosureUrl;
  final file = url == null ? null : audioFileFor?.call(work.id, url);
  final mayGo =
      kind != VoiceKind.cloned || await clonedVoiceShareAllowed(db);
  return (
    audio: file != null && file.existsSync() && mayGo ? file : null,
    title: work.title,
    text: text,
  );
}

/// The media type of an audio file, by its extension.
String audioMimeTypeOf(String path) {
  final dot = path.lastIndexOf('.');
  return switch (dot < 0 ? '' : path.substring(dot).toLowerCase()) {
    '.ogg' || '.opus' || '.oga' => 'audio/ogg',
    '.m4a' || '.mp4' || '.aac' => 'audio/mp4',
    '.wav' => 'audio/wav',
    '.mp3' => 'audio/mpeg',
    '.flac' => 'audio/flac',
    _ => 'audio/*',
  };
}

/// A copy of [audio] named by [title], in [dir], for the share sheet: the
/// app keeps its audio under a number, and the person receiving it should
/// see the episode's name. [dir] is emptied first, so only the newest
/// share's copy is ever kept.
Future<File> namedCopyForShare(File audio, String title, Directory dir) async {
  if (dir.existsSync()) await dir.delete(recursive: true);
  await dir.create(recursive: true);
  final dot = audio.path.lastIndexOf('.');
  final ext = dot < 0 ? '' : audio.path.substring(dot);
  var name = title
      // \x22 is the double quote, which many file systems refuse.
      .replaceAll(RegExp(r'[/\\:*?<>|\x00-\x1f\x22]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (name.length > 120) name = name.substring(0, 120).trim();
  if (name.isEmpty || name.startsWith('.')) name = 'Episode';
  return audio.copy('${dir.path}/$name$ext');
}
