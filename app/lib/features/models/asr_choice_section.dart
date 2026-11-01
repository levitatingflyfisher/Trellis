/// "Transcription quality" on the Models page (1.6.0): the listener
/// picks which whisper model transcribes. See `asr_choice.dart`.
library;

import 'package:flutter/material.dart';
import 'package:ml_runtime/ml_runtime.dart';

import '../../db/database.dart';
import '../transcribe/asr_choice.dart';

class AsrChoiceSection extends StatefulWidget {
  const AsrChoiceSection(
      {super.key, required this.db, required this.registry, required this.tier});
  final AppDatabase db;
  final ModelRegistry registry;
  final DeviceTier tier;

  @override
  State<AsrChoiceSection> createState() => _AsrChoiceSectionState();
}

class _AsrChoiceSectionState extends State<AsrChoiceSection> {
  String? _chosen;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final stored = await widget.db.deviceSettingsDao.read(asrModelKey);
    if (!mounted) return;
    setState(() {
      _chosen = asrModelFor(widget.registry, widget.tier, stored)?.id;
      _loaded = true;
    });
  }

  Future<void> _choose(String? id) async {
    if (id == null) return;
    setState(() => _chosen = id);
    await widget.db.deviceSettingsDao.write(asrModelKey, id);
  }

  @override
  Widget build(BuildContext context) {
    final choices = asrChoices(widget.registry);
    if (!_loaded || choices.length < 2) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
          child: Text('Transcription quality',
              style: theme.textTheme.titleMedium),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Text(
              'Used the next time something is transcribed. Transcripts '
              'already made stay as they are.',
              style: theme.textTheme.bodyMedium),
        ),
        RadioGroup<String>(
          groupValue: _chosen,
          onChanged: _choose,
          child: Column(
            children: [
              for (final spec in choices)
                RadioListTile<String>(
                  key: Key('asr-choice-${spec.id}'),
                  value: spec.id,
                  title: Text(asrChoiceTitle(spec)),
                  subtitle: Text(asrChoiceNote(spec)),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
