/// Which languages the one tap offers, and why one a listener may look
/// for is not there (board-0126, owner: "I'd like it to work for eg
/// russian, japanese, german, not just spanish").
///
/// A language is offered when two things are both true: a translator
/// reaches it from the episode's language, and a voice on this device can
/// save it as audio (the downloaded voice, or the phone's own). Every
/// other language a listener might expect is missing for one of those two
/// reasons, and the dialog says which.
library;

import '../reader/translation/language_names.dart';

/// The one-tap languages for one episode, sorted three ways.
class ListenLanguages {
  /// Offered: a translator reaches it and a voice can save it.
  final List<String> offered;

  /// A translator reaches it, and no voice on this device can save it.
  final List<String> noVoice;

  /// A voice can save it, and no translator reaches it from the
  /// episode's language. Only languages Trellis translates in some
  /// direction are named: the phone may speak dozens Trellis has never
  /// translated, and nobody looks for those here.
  final List<String> noTranslator;

  const ListenLanguages(
      {this.offered = const [],
      this.noVoice = const [],
      this.noTranslator = const []});
}

/// Sorts every language in [candidates] for an episode in [source]:
/// [hasRoute] says whether a translator reaches it, [canSave] whether a
/// voice can save it, [translated] the languages any translator knows.
/// The episode's own language is never one of them. Each list is in tag
/// order, so it reads the same every time.
ListenLanguages sortListenLanguages({
  required String source,
  required Set<String> candidates,
  required bool Function(String lang) hasRoute,
  required bool Function(String lang) canSave,
  required Set<String> translated,
}) {
  final offered = <String>[], noVoice = <String>[], noTranslator = <String>[];
  for (final lang in [...candidates]..sort()) {
    if (lang == source) continue;
    final route = hasRoute(lang), voice = canSave(lang);
    if (route && voice) {
      offered.add(lang);
    } else if (route) {
      noVoice.add(lang);
    } else if (voice && translated.contains(lang)) {
      noTranslator.add(lang);
    }
  }
  return ListenLanguages(
      offered: offered, noVoice: noVoice, noTranslator: noTranslator);
}

/// One or two plain sentences under the dialog's list, saying why the
/// languages a listener may look for are missing; null when none is.
/// [source] is the episode's language, or null when the list is for no
/// one episode (the setting).
String? listenMissingNote(ListenLanguages languages,
    {required String? source}) {
  final sentences = [
    if (languages.noVoice.isNotEmpty)
      'There is no voice on this phone for ${_names(languages.noVoice)}: '
          'add one in Android’s Settings, under Text-to-speech output.',
    if (languages.noTranslator.isNotEmpty)
      source == null
          ? 'Trellis has no translator into '
              '${_names(languages.noTranslator)} yet.'
          : 'Trellis has no translator from ${languageDisplayName(source)} '
              'into ${_names(languages.noTranslator)} yet.',
  ];
  return sentences.isEmpty ? null : sentences.join(' ');
}

String _names(List<String> langs) {
  final names = [for (final l in langs) languageDisplayName(l)]..sort();
  if (names.length < 2) return names.join();
  return '${names.sublist(0, names.length - 1).join(', ')} and '
      '${names.last}';
}
