/// Which voice reads each language aloud (1.5.9, user: "I can transcribe
/// a podcast and translate it to Russian, but I can't get the Russian text
/// to speech").
///
/// Two kinds of voice: the downloaded one (Supertonic, ADR-0007: English
/// and Spanish only; its character table has no Cyrillic or CJK at all,
/// docs/reference/tts-voices.md) and the phone's own (flutter_tts over
/// Android's text-to-speech engine, one or more voices per installed
/// language). A run reads on ONE kind: the downloaded voice plays a
/// gapless queue the app owns, the phone's voice is spoken a sentence at
/// a time, and the two never interleave. So a run that needs any language
/// the downloaded voice can't read (Russian under its English original)
/// is read entirely by the phone's voices.
///
/// A language no voice can read is refused before a word is spoken
/// ([ReadAloudVoicePlan.missing]): an English voice reading Russian is
/// worse than a sentence saying why nothing was read.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../../services/device_services.dart' show SystemVoice;
import '../reader_prefs.dart';
import '../translation/language_names.dart';
import 'supertonic_voice_handle.dart' show supertonicSupportedLangs;

/// One run's voices, decided before it starts.
class ReadAloudVoicePlan {
  /// The whole run reads on the downloaded voice.
  final bool neural;

  /// Under the phone's voices, the one picked for each language; null (or
  /// absent) is that language's default voice.
  final Map<String, SystemVoice?> systemVoices;

  /// Languages in the run that no voice on this device can read.
  final Set<String> missing;

  const ReadAloudVoicePlan(
      {required this.neural,
      this.systemVoices = const {},
      this.missing = const {}});
}

/// The languages a downloaded voice primed for a work in [workLang]
/// reads: the one it was picked for, and those the voice itself speaks.
Set<String> neuralLangsFor(String? workLang) =>
    {?workLang, ...supertonicSupportedLangs};

/// Whether the downloaded voice reads [lang] for this listener: it can
/// ([neuralLangs], empty when there is no downloaded voice or it is set
/// aside), and nobody picked a phone voice for it instead.
bool neuralReads(String lang,
        {required Set<String> neuralLangs,
        required Map<String, String> choices}) =>
    neuralLangs.contains(lang) &&
    (choices[lang] ?? readAloudNeuralVoice) == readAloudNeuralVoice;

/// Decides one run's voices for [langs] (bare tags). [neuralLangs]: what
/// the downloaded voice reads, empty when there is none or it is set
/// aside ("Use the system voice"). [installed] is the phone's voice list,
/// or null where it can't be listed (then nothing is known missing; the
/// engine's own refusal at the sentence is the guard).
ReadAloudVoicePlan planReadAloud({
  required Set<String> langs,
  required Set<String> neuralLangs,
  required Map<String, String> choices,
  required List<SystemVoice>? installed,
}) {
  if (neuralLangs.isNotEmpty &&
      langs.every((l) =>
          neuralReads(l, neuralLangs: neuralLangs, choices: choices))) {
    return const ReadAloudVoicePlan(neural: true);
  }
  final voices = <String, SystemVoice?>{};
  final missing = <String>{};
  for (final lang in langs) {
    if (installed != null && !installed.any((v) => v.lang == lang)) {
      missing.add(lang);
      continue;
    }
    voices[lang] = _picked(lang, choices, installed);
  }
  return ReadAloudVoicePlan(
      neural: false, systemVoices: voices, missing: missing);
}

SystemVoice? _picked(
    String lang, Map<String, String> choices, List<SystemVoice>? installed) {
  final choice = choices[lang];
  if (choice == null || !choice.startsWith(readAloudSystemVoicePrefix)) {
    return null;
  }
  final name = choice.substring(readAloudSystemVoicePrefix.length);
  for (final v in installed ?? const <SystemVoice>[]) {
    if (v.name == name && v.lang == lang) return v;
  }
  // Not listed (or not listable): ask for it by name anyway; the speaker
  // falls back to the language's default if the engine no longer has it.
  return installed == null ? SystemVoice(name: name, locale: lang) : null;
}

/// One choice in the voices sheet.
class ReadAloudVoiceOption {
  final String id;
  final String label;
  final String? detail;
  const ReadAloudVoiceOption(this.id, this.label, [this.detail]);
}

/// The voices that can read [lang], in the order the sheet lists them.
/// Empty when none can. The phone's are numbered in a steady order (by
/// locale, on the phone before needing the internet, then by name), so
/// "Voice 2" is the same voice every time the sheet opens, whatever
/// order the engine listed them in.
List<ReadAloudVoiceOption> readAloudVoiceOptions(String lang,
    {required Set<String> neuralLangs,
    required List<SystemVoice>? installed}) {
  final phone = installed?.where((v) => v.lang == lang).toList()
    ?..sort((a, b) {
      final byLocale = a.locale.compareTo(b.locale);
      if (byLocale != 0) return byLocale;
      if (a.needsInternet != b.needsInternet) return a.needsInternet ? 1 : -1;
      return a.name.compareTo(b.name);
    });
  return [
    if (neuralLangs.contains(lang))
      const ReadAloudVoiceOption(readAloudNeuralVoice, 'Downloaded voice',
          'Smoother, made on this phone'),
    if (phone == null || phone.isNotEmpty)
      const ReadAloudVoiceOption(readAloudDefaultVoice, 'Default voice'),
    for (var i = 0; i < (phone?.length ?? 0); i++)
      ReadAloudVoiceOption(
          '$readAloudSystemVoicePrefix${phone![i].name}',
          'Voice ${i + 1}',
          phone[i].needsInternet
              ? '${localeDisplayName(phone[i].locale)} · needs internet'
              : localeDisplayName(phone[i].locale)),
  ];
}

/// The option [choices] names for [lang], or the default one when that
/// choice is not on offer (a voice since removed).
String selectedVoiceId(String lang, Map<String, String> choices,
    List<ReadAloudVoiceOption> options) {
  final choice = choices[lang];
  if (choice != null && options.any((o) => o.id == choice)) return choice;
  return options.isEmpty ? readAloudDefaultVoice : options.first.id;
}

/// What to say when [lang] has no voice: plain, with where to get one.
/// [internetVoice]: the phone lists a voice for it that needs the
/// internet (the engine turned the language down all the same, offline),
/// so the message doesn't say there is none. [originalLang]: under Both,
/// the language of the original, heard alone with the translation's
/// reading turned off.
String noVoiceMessage(String lang,
    {bool internetVoice = false, String? originalLang}) {
  final name = languageDisplayName(lang);
  final String why;
  if (kIsWeb) {
    why = 'No $name voice in this browser, so read aloud can’t read the '
        '$name.';
  } else if (internetVoice) {
    why = 'The $name voice on this phone needs the internet, so read aloud '
        'can’t read the $name now. Connect, or add an offline $name voice '
        'in Android’s Settings, under Text-to-speech output.';
  } else {
    why = 'No $name voice is installed, so read aloud can’t read the '
        '$name. Add one in Android’s Settings, under Text-to-speech output.';
  }
  if (originalLang == null) return why;
  return '$why To hear the ${languageDisplayName(originalLang)} alone, turn '
      'off “Read the $name aloud too” in the menu.';
}

/// The Read aloud voices sheet: for each language this work reads in, the
/// voices that can read it, the current one picked. [onPick] remembers a
/// pick for that language.
class ReadAloudVoicesSheet extends StatefulWidget {
  final List<String> langs;
  final Set<String> neuralLangs;
  final List<SystemVoice>? installed;
  final Map<String, String> choices;
  final void Function(String lang, String voiceId) onPick;

  /// There is a downloaded voice, and "Use the system voice" (the master
  /// switch, ADR-0006) has set it aside: the sheet says so, rather than
  /// leaving the downloaded voice missing from its lists unexplained.
  final bool systemVoiceOn;

  const ReadAloudVoicesSheet({
    super.key,
    required this.langs,
    required this.neuralLangs,
    required this.installed,
    required this.choices,
    required this.onPick,
    this.systemVoiceOn = false,
  });

  @override
  State<ReadAloudVoicesSheet> createState() => _ReadAloudVoicesSheetState();
}

class _ReadAloudVoicesSheetState extends State<ReadAloudVoicesSheet> {
  late final Map<String, String> _choices = {...widget.choices};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: ListView(
          key: const Key('read-aloud-voices-sheet'),
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Read aloud voices',
                  style: theme.textTheme.titleMedium),
            ),
            if (widget.systemVoiceOn)
              const Padding(
                key: Key('voices-system-voice-on'),
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text('“Use the system voice” is on, so the '
                    'downloaded voice is set aside. Turn it off in the menu '
                    'to choose the downloaded voice.'),
              ),
            if (widget.langs.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Text('Set the language this is in first (the '
                    'menu’s Language item), then choose a voice for it.'),
              ),
            for (final lang in widget.langs) ..._section(lang, theme),
          ],
        ),
      ),
    );
  }

  List<Widget> _section(String lang, ThemeData theme) {
    final options = readAloudVoiceOptions(lang,
        neuralLangs: widget.neuralLangs, installed: widget.installed);
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(languageDisplayName(lang),
            style: theme.textTheme.labelLarge),
      ),
      if (options.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(noVoiceMessage(lang), key: Key('voice-$lang-none')),
        )
      else
        RadioGroup<String>(
          groupValue: selectedVoiceId(lang, _choices, options),
          onChanged: (id) {
            if (id == null) return;
            setState(() => _choices[lang] = id);
            widget.onPick(lang, id);
          },
          child: Column(children: [
            for (final o in options)
              RadioListTile<String>(
                key: Key('voice-$lang-'
                    '${o.id.startsWith(readAloudSystemVoicePrefix) ? o.id.substring(readAloudSystemVoicePrefix.length) : o.id}'),
                value: o.id,
                title: Text(o.label),
                subtitle: o.detail == null ? null : Text(o.detail!),
              ),
          ]),
        ),
    ];
  }
}
