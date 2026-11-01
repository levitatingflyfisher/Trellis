/// Which voice saves an episode's audio (board-0126).
///
/// Two kinds can: the downloaded voice (Supertonic: English, Spanish,
/// French, Portuguese), which sounds smoother, and the phone's own, which
/// speaks every language the phone has a voice for. The listener's say is
/// the voice they chose for the language in Read aloud's voices: one
/// place to choose a voice, for hearing and for keeping alike. A phone
/// voice chosen there (its default or a numbered one) saves with the
/// phone; the downloaded voice chosen there saves with it.
library;

import '../reader/reader_prefs.dart'
    show readAloudDefaultVoice, readAloudNeuralVoice, readAloudSystemVoicePrefix;

/// The two kinds of voice whose speech can be kept as a file.
enum SavedVoiceKind { downloaded, phone }

/// The voice that saves a language, or null when none can.
///
/// [downloadedSpeaks]: the downloaded voice speaks it; [downloadedHere]:
/// and it is on the device; [phoneSpeaks]: the phone has a voice for it;
/// [choice]: what Read aloud's voices hold for it.
///
/// Without a choice: the downloaded voice where it speaks the language
/// and is here; else the phone's, which fetches nothing; else the
/// downloaded voice, fetched once with the listener's yes. A choice that
/// cannot be kept (the phone has no such voice) falls back to that.
SavedVoiceKind? savedVoiceKind({
  required bool downloadedSpeaks,
  required bool downloadedHere,
  required bool phoneSpeaks,
  String? choice,
}) {
  final wantsPhone = choice == readAloudDefaultVoice ||
      (choice?.startsWith(readAloudSystemVoicePrefix) ?? false);
  if (wantsPhone && phoneSpeaks) return SavedVoiceKind.phone;
  if (choice == readAloudNeuralVoice && downloadedSpeaks) {
    return SavedVoiceKind.downloaded;
  }
  if (downloadedSpeaks && downloadedHere) return SavedVoiceKind.downloaded;
  if (phoneSpeaks) return SavedVoiceKind.phone;
  if (downloadedSpeaks) return SavedVoiceKind.downloaded;
  return null;
}
