/// How a made episode names its original (1.6.0): its guid is
/// `spoken:<original's work id>:<language>`. Pure, so the pages and lists
/// that link an episode to its versions can read it on every tier.
library;

/// The guid of the spoken translation of work [originalId] into [lang]:
/// how it is found again, so it is made once.
String spokenGuid(int originalId, String lang) => 'spoken:$originalId:$lang';

/// Whether [guid] is a made episode's.
bool isSpokenGuid(String guid) => guid.startsWith('spoken:');

/// The original's work id and the language of the made episode whose
/// guid is [guid]; null for any other guid.
({int originalId, String lang})? parseSpokenGuid(String guid) {
  final parts = guid.split(':');
  if (parts.length != 3 || parts[0] != 'spoken') return null;
  final id = int.tryParse(parts[1]);
  if (id == null || parts[2].isEmpty) return null;
  return (originalId: id, lang: parts[2]);
}
