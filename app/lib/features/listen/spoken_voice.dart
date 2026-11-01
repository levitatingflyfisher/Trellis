/// The voice a made episode is spoken in, and how it is named in words.
/// Pure, and the same on every tier: Share reads it on the web too.
library;

/// The kind of voice that says a made episode. Today every saved voice
/// is a [machine] voice. A [cloned] voice copies a real person (the
/// host's own voice, asked for by the owner); its file is shared only
/// when Settings › Share audio made in a host’s own voice is on.
enum VoiceKind { machine, cloned }

/// How the voice is named in words: on the episode's page, in its
/// file's tag and in what Share sends with it.
String spokenVoicePhrase(VoiceKind kind) => switch (kind) {
      VoiceKind.machine => 'a machine-made voice',
      VoiceKind.cloned => 'a machine-made copy of a real person’s voice',
    };

/// The comment tag a made episode's file carries, so the label travels
/// with the file wherever it is shared.
String spokenAudioComment(String voice, VoiceKind kind) => switch (kind) {
      VoiceKind.machine => 'Machine-made voice ($voice). Translated and '
          'spoken by Trellis.',
      VoiceKind.cloned => 'Machine-made copy of a real person’s voice '
          '($voice). Translated and spoken by Trellis.',
    };
