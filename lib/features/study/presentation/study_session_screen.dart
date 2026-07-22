import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/markdown.dart';
import '../../../core/providers.dart';
import '../../../core/time.dart';
import '../../curriculum/domain/models.dart';
import '../domain/grading.dart';
import '../domain/progress.dart';
import '../domain/sm2_scheduler.dart';
import 'rsvp_reader.dart';

final _clozeRe = RegExp(r'\{\{(c\d+)(?:::([^}]*))?\}\}');

sealed class _Step {}

class _IntakeStep extends _Step {
  _IntakeStep(this.node);
  final KnowledgeNode node;
}

class _ItemStep extends _Step {
  _ItemStep(this.node, this.item);
  final KnowledgeNode node;
  final RetrievalItem item;
}

class StudySessionScreen extends ConsumerStatefulWidget {
  const StudySessionScreen({super.key, required this.course});
  final Course course;

  @override
  ConsumerState<StudySessionScreen> createState() => _StudySessionScreenState();
}

class _StudySessionScreenState extends ConsumerState<StudySessionScreen> {
  late final int _today;
  late final Map<String, CardState> _cards;
  late final List<_Step> _steps;
  final Map<String, TextEditingController> _ctls = {};
  int _i = 0;
  bool _revealed = false;
  int? _chosen;
  int _reviewed = 0;

  @override
  void initState() {
    super.initState();
    // One authoritative day + one card load for the whole session.
    _today = epochDayNow();
    _cards = ref.read(cardRepositoryProvider).load(widget.course.id);
    _steps = _buildQueue(_cards, _today);
  }

  @override
  void dispose() {
    for (final c in _ctls.values) {
      c.dispose();
    }
    super.dispose();
  }

  List<_Step> _buildQueue(Map<String, CardState> cards, int today) {
    final steps = <_Step>[];
    for (final node in widget.course.nodes) {
      // Lock only first exposure: a node already started stays available, so a
      // lapse on a prerequisite never buries reviews the learner already owns.
      final started = node.items.any((it) => cards[it.id] != null);
      if (!started && !nodeUnlocked(node, widget.course, cards, today)) continue;
      final due = node.items.where((it) {
        final c = cards[it.id];
        return c == null || c.isDue(today);
      }).toList();
      if (due.isEmpty) continue;
      steps.add(_IntakeStep(node));
      for (final it in due) {
        steps.add(_ItemStep(node, it));
      }
    }
    return steps;
  }

  TextEditingController _ctl(String key) =>
      _ctls.putIfAbsent(key, () => TextEditingController());

  void _advance() {
    setState(() {
      _i++;
      _revealed = false;
      _chosen = null;
    });
  }

  void _grade(RetrievalItem item, Grade g) {
    final node = switch (_steps[_i]) {
      _ItemStep(:final node) => node,
      _ => null,
    };
    final card = _cards[item.id] ??
        CardState.initial(item.id, widget.course.srsDefaults, _today);
    final next = scheduleSm2(card, g, _today,
        firstIntervalDays: widget.course.srsDefaults.firstIntervalDays);
    _cards[item.id] = next;
    // The in-memory map is authoritative; persist it in the background (no
    // reload+decode of the whole store) so the UI advances immediately.
    unawaited(ref.read(cardRepositoryProvider).save(widget.course.id, _cards));
    // A lapse ("Again") sets the card due today — relearn it in THIS session,
    // honouring the scheduler's stated intent, by re-queuing it at the end.
    if (node != null && next.isDue(_today)) _steps.add(_ItemStep(node, item));
    _reviewed++;
    _advance();
  }

  @override
  Widget build(BuildContext context) {
    if (_steps.isEmpty || _i >= _steps.length) {
      return _DoneScreen(reviewed: _reviewed);
    }
    final step = _steps[_i];
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.course.title),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(value: (_i + 1) / _steps.length, minHeight: 4),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: switch (step) {
            _IntakeStep(:final node) => _buildIntake(node),
            _ItemStep(:final node, :final item) => _buildItem(node, item),
          },
        ),
      ),
    );
  }

  Widget _buildIntake(KnowledgeNode node) {
    final theme = Theme.of(context);
    final blocks = _intakeBlocks(node);
    final headers = <Widget>[
      Text('Read', style: theme.textTheme.labelMedium),
      Text(node.title, style: theme.textTheme.headlineSmall),
      if (node.summary.isNotEmpty) ...[
        const SizedBox(height: 4),
        Text(node.summary, style: theme.textTheme.bodyMedium),
      ],
      const SizedBox(height: 16),
      RsvpReader(text: strippedForRsvp(node.intake)),
      const SizedBox(height: 16),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          // ListView.builder so each heavy markdown/LaTeX block lays out only
          // when scrolled near, instead of the whole passage in one frame.
          child: ListView.builder(
            itemCount: headers.length + blocks.length,
            itemBuilder: (context, i) {
              if (i < headers.length) return headers[i];
              return Card(
                color: theme.colorScheme.surfaceContainerHighest,
                margin: const EdgeInsets.only(bottom: 8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: MdText(blocks[i - headers.length]),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        // Pinned so the next action is always reachable below a long passage.
        FilledButton.icon(
          onPressed: _advance,
          icon: const Icon(Icons.psychology_alt_outlined),
          label: const Text('Recall'),
        ),
      ],
    );
  }

  Widget _buildItem(KnowledgeNode node, RetrievalItem item) {
    final theme = Theme.of(context);
    return ListView(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(node.title,
                  style: theme.textTheme.labelMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 8),
            _RungChip(rung: item.rung),
          ],
        ),
        if (!_revealed && item.hints.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Need a hint?'),
            children: [
              for (final h in item.hints)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('• $h'),
                  ),
                ),
            ],
          ),
        const SizedBox(height: 12),
        switch (item) {
          ClozeItem() => _cloze(item),
          QaItem() => _qa(item),
          DiscriminationItem() => _discrimination(item),
          ProcedureItem() => _procedure(item),
        },
        if (_revealed && item.sources.isNotEmpty) ...[
          const SizedBox(height: 12),
          _AnswerBox(label: 'Sources', body: item.sources.join('\n')),
        ],
      ],
    );
  }

  // ---- cloze -------------------------------------------------------------
  Widget _cloze(ClozeItem item) {
    final theme = Theme.of(context);
    final keys = clozeKeysInTextOrder(item.text, item.answers.keys);
    final display = item.text.replaceAll(_clozeRe, '  ____  ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MdText(display, style: theme.textTheme.titleLarge),
        const SizedBox(height: 16),
        for (var j = 0; j < keys.length; j++) _clozeBlank(item, keys[j], j),
        if (_revealed) ...[
          const SizedBox(height: 8),
          for (final k in keys)
            MdText('• $k: ${item.answers[k]}'),
        ],
        const SizedBox(height: 16),
        if (!_revealed)
          FilledButton(
            onPressed: () => setState(() => _revealed = true),
            child: const Text('Check'),
          )
        else
          _grades(item, suggestion: _clozeAuto(item) ? Grade.good : Grade.again),
      ],
    );
  }

  bool _clozeAuto(ClozeItem item) {
    final responses = {
      for (final k in item.answers.keys) k: _ctl('${item.id}:$k').text
    };
    return gradeCloze(item, responses);
  }

  // One cloze blank. Computes correctness once (via the canonical
  // normalizeAnswer) instead of normalizing each side twice inline.
  Widget _clozeBlank(ClozeItem item, String key, int index) {
    final theme = Theme.of(context);
    final controller = _ctl('${item.id}:$key');
    final correct =
        normalizeAnswer(controller.text) == normalizeAnswer(item.answers[key]!);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: controller,
        enabled: !_revealed,
        decoration: InputDecoration(
          labelText: 'Blank ${index + 1}',
          border: const OutlineInputBorder(),
          suffixIcon: !_revealed
              ? null
              : Icon(
                  correct ? Icons.check_circle : Icons.cancel,
                  color: correct ? Colors.green : theme.colorScheme.error,
                ),
        ),
      ),
    );
  }

  // Split an intake passage into paragraph/block chunks once per node so the
  // reading surface can lay them out lazily (one ListView item each).
  final _blockCache = <String, List<String>>{};
  List<String> _intakeBlocks(KnowledgeNode node) =>
      _blockCache.putIfAbsent(node.id, () {
        final parts = node.intake
            .split(RegExp(r'\n[ \t]*\n'))
            .map((b) => b.trim())
            .where((b) => b.isNotEmpty)
            .toList();
        return parts.isEmpty ? [node.intake] : parts;
      });

  // ---- free recall (qa / procedure share one scaffold) ------------------
  Widget _qa(QaItem item) => _freeRecall(
        item: item,
        prompt: item.prompt,
        hintText: 'Recall it in your own words…',
        revealLabel: 'Reveal answer',
        rubric: item.rubric,
        reveal: [_AnswerBox(label: 'Answer', body: item.answer)],
        suggestion: suggestGrade(
            keywordCoverage(item.acceptable, _ctl('${item.id}:a').text)),
      );

  Widget _freeRecall({
    required RetrievalItem item,
    required String prompt,
    required String hintText,
    required String revealLabel,
    required List<Widget> reveal,
    required Grade suggestion,
    String? rubric,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MdText(prompt, style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        TextField(
          controller: _ctl('${item.id}:a'),
          enabled: !_revealed,
          minLines: 3,
          maxLines: 8,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            hintText: hintText,
          ),
        ),
        if (_revealed) ...[
          const SizedBox(height: 16),
          ...reveal,
          if (rubric != null) ...[
            const SizedBox(height: 8),
            _AnswerBox(label: 'Self-grade against', body: rubric),
          ],
        ],
        const SizedBox(height: 16),
        if (!_revealed)
          FilledButton(
            onPressed: () => setState(() => _revealed = true),
            child: Text(revealLabel),
          )
        else
          _grades(item, suggestion: suggestion),
      ],
    );
  }

  // ---- discrimination ----------------------------------------------------
  Widget _discrimination(DiscriminationItem item) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MdText(item.prompt, style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        for (var k = 0; k < item.choices.length; k++)
          Card(
            color: !_revealed
                ? null
                : (k == item.correctIndex
                    ? Colors.green.withValues(alpha: 0.18)
                    : (k == _chosen ? theme.colorScheme.errorContainer : null)),
            child: RadioListTile<int>(
              value: k,
              groupValue: _chosen,
              onChanged: _revealed ? null : (v) => setState(() => _chosen = v),
              title: MdText(item.choices[k]),
            ),
          ),
        if (_revealed && item.explanation != null) ...[
          const SizedBox(height: 8),
          _AnswerBox(label: 'Why', body: item.explanation!),
        ],
        const SizedBox(height: 16),
        if (!_revealed)
          FilledButton(
            onPressed: _chosen == null
                ? null
                : () => setState(() => _revealed = true),
            child: const Text('Check'),
          )
        else
          _grades(
            item,
            suggestion: gradeDiscrimination(item, _chosen ?? -1)
                ? Grade.good
                : Grade.again,
          ),
      ],
    );
  }

  // ---- procedure ---------------------------------------------------------
  Widget _procedure(ProcedureItem item) {
    final theme = Theme.of(context);
    return _freeRecall(
      item: item,
      prompt: item.prompt,
      hintText: 'Recall / perform the steps…',
      revealLabel: 'Reveal steps',
      rubric: item.rubric,
      // No `acceptable` anchors to grade against, so don't pre-bless a pass:
      // suggest "Again" on an empty recall, otherwise leave "Good" as the nudge.
      suggestion: _ctl('${item.id}:a').text.trim().isEmpty ? Grade.again : Grade.good,
      reveal: [
        Text('Steps', style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        for (var s = 0; s < item.steps.length; s++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: MdText('${s + 1}. ${item.steps[s]}'),
          ),
      ],
    );
  }

  // ---- shared grade row --------------------------------------------------
  Widget _grades(RetrievalItem item, {required Grade suggestion}) {
    Widget b(Grade g, String label, Color c) => Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: g == suggestion
                ? FilledButton(
                    onPressed: () => _grade(item, g),
                    style: FilledButton.styleFrom(backgroundColor: c),
                    child: Text(label),
                  )
                : OutlinedButton(
                    onPressed: () => _grade(item, g),
                    child: Text(label),
                  ),
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('How did that go?', style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 6),
        Row(
          children: [
            b(Grade.again, 'Again', Colors.red.shade400),
            b(Grade.hard, 'Hard', Colors.orange.shade400),
            b(Grade.good, 'Good', Colors.green.shade400),
            b(Grade.easy, 'Easy', Colors.blue.shade400),
          ],
        ),
      ],
    );
  }

}

class _RungChip extends StatelessWidget {
  const _RungChip({required this.rung});
  final int rung;
  @override
  Widget build(BuildContext context) {
    const labels = {1: 'cued', 2: 'recall', 3: 'generate', 4: 'free'};
    return Chip(
      visualDensity: VisualDensity.compact,
      label: Text('rung $rung · ${labels[rung] ?? ''}'),
    );
  }
}

class _AnswerBox extends StatelessWidget {
  const _AnswerBox({required this.label, required this.body});
  final String label;
  final String body;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelMedium),
          const SizedBox(height: 4),
          MdText(body),
        ],
      ),
    );
  }
}

class _DoneScreen extends StatelessWidget {
  const _DoneScreen({required this.reviewed});
  final int reviewed;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Session complete')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.celebration_outlined, size: 56),
            const SizedBox(height: 12),
            Text(reviewed == 0 ? 'Nothing due right now' : 'Reviewed $reviewed items',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}
