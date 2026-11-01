/// The learning-language picker: every language Trellis can name, each
/// with what works in it today (owner, 12 Nov: "pick ANY language to
/// learn ... show plainly what works today: reading, cards, transcribing
/// (whisper), translating, speaking").
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../reader/translation/language_names.dart';
import '../shared/capped_body.dart';
import 'language_abilities.dart';

/// Pops with the chosen language code, or null.
class LearningLanguagePage extends StatefulWidget {
  const LearningLanguagePage({
    super.key,
    required this.load,
    required this.chosen,
    this.changes,
    this.openVoiceSettings,
  });

  /// What works in each language; asked again when [changes] fires (a
  /// voice added in Android's settings, a model downloaded).
  final Future<List<LanguageAbilities>> Function() load;
  final Listenable? changes;
  final String? chosen;

  /// Opens Android's text-to-speech settings; null hides the button.
  final Future<bool> Function()? openVoiceSettings;

  @override
  State<LearningLanguagePage> createState() => _LearningLanguagePageState();
}

class _LearningLanguagePageState extends State<LearningLanguagePage> {
  List<LanguageAbilities>? _rows;
  String _query = '';

  @override
  void initState() {
    super.initState();
    widget.changes?.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    widget.changes?.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    unawaited(widget.load().then((rows) {
      if (mounted) setState(() => _rows = rows);
    }));
  }

  bool _matches(String lang) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return lang == q || languageDisplayName(lang).toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final shown = rows == null
        ? const <LanguageAbilities>[]
        : [for (final r in rows) if (_matches(r.lang)) r];
    final making = [for (final r in shown) if (r.makesEpisodes) r];
    final items = <Object>[
      if (making.isNotEmpty) ...[
        'Episodes can be made in these',
        ...making,
        'Every language',
      ],
      ...shown,
    ];
    return Scaffold(
      key: const Key('learning-language-dialog'),
      appBar: AppBar(title: const Text('Which language are you learning?')),
      body: CappedBody(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextField(
                key: const Key('learning-language-search'),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Find a language',
                ),
                onChanged: (q) => setState(() => _query = q),
              ),
            ),
            Expanded(
              child: rows == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      key: const Key('learning-language-list'),
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: items.length + 1,
                      itemBuilder: (context, i) {
                        if (i == 0) return _legend(context);
                        final item = items[i - 1];
                        return item is String
                            ? _heading(context, item)
                            : _row(context, item as LanguageAbilities,
                                inMaking: i - 1 <= making.length);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _heading(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Semantics(
          header: true,
          child: Text(text,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary)),
        ),
      );

  Widget _legend(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    final settings = widget.openVoiceSettings;
    return Padding(
      key: const Key('learning-language-legend'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: const [
              AbilityMark(Ability.works, 'works on this phone'),
              AbilityMark(Ability.download, 'needs a download'),
              AbilityMark(Ability.notYet, 'not there yet'),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Any language can be read and studied with cards. Episodes can '
            'be made where it can be transcribed, translated and spoken. '
            'Transcribing makes more mistakes in a language with little '
            'recorded speech.',
            style: small,
          ),
          if (settings != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: const Key('learning-language-voice-settings'),
                onPressed: () async {
                  final messenger = ScaffoldMessenger.maybeOf(context);
                  if (!await settings()) {
                    messenger?.showSnackBar(const SnackBar(
                        persist: false,
                        content: Text('This phone’s settings wouldn’t open '
                            'here. Look for Text-to-speech output in '
                            'Android’s Settings.')));
                  }
                  _reload();
                },
                child: const Text('Add a voice in text-to-speech settings'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, LanguageAbilities a,
      {required bool inMaking}) {
    final name = languageDisplayName(a.lang);
    final chosen = a.lang == widget.chosen;
    final ways = switch (a.translateWays) {
      TranslateWays.fromEnglish => 'Translate from English',
      TranslateWays.intoEnglish => 'Translate into English',
      _ => 'Translate',
    };
    return Semantics(
      button: true,
      selected: chosen,
      label: a.spoken(name),
      excludeSemantics: true,
      child: InkWell(
        // A language in both lists is keyed once, in the first.
        key: Key(inMaking || !a.makesEpisodes
            ? 'learning-language-${a.lang}'
            : 'learning-language-all-${a.lang}'),
        onTap: () => Navigator.of(context).pop(a.lang),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(name,
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  if (chosen) const Icon(Icons.check),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 12,
                runSpacing: 2,
                children: [
                  AbilityMark(a.reading, 'Read'),
                  AbilityMark(a.cards, 'Cards'),
                  AbilityMark(a.transcribe, 'Transcribe'),
                  AbilityMark(a.translate, ways),
                  AbilityMark(a.speak, 'Speak'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One mark: an icon for works, download or not yet, and a word.
class AbilityMark extends StatelessWidget {
  const AbilityMark(this.ability, this.word, {super.key});

  final Ability ability;
  final String word;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (ability) {
      Ability.works => (Icons.check_circle, scheme.primary),
      Ability.download => (Icons.download_for_offline_outlined, scheme.tertiary),
      Ability.notYet => (Icons.remove_circle_outline, scheme.outline),
    };
    final style = Theme.of(context).textTheme.bodySmall;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            word,
            style: ability == Ability.notYet
                ? style?.copyWith(color: scheme.onSurfaceVariant)
                : style,
          ),
        ),
      ],
    );
  }
}
