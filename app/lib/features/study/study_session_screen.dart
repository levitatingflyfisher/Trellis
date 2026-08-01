import 'dart:convert';

import 'package:brain_wiring/brain_wiring.dart' as brain;
import 'package:flutter/material.dart';
import 'package:study_core/study_core.dart' as study;

import '../../db/database.dart' hide Alignment;
import '../brain/brain_labels.dart';
import '../brain/brain_store.dart';
import '../intake/paste_intake.dart' show epochDayUtcNow;
import '../models/consent.dart';

final _clozeRe = RegExp(r'\{\{(c\d+)(?:::([^}]*))?\}\}');

sealed class _Step {}

class _IntakeStep extends _Step {
  _IntakeStep(this.node);
  final study.KnowledgeNode node;
}

class _ItemStep extends _Step {
  _ItemStep(this.node, this.item);
  final study.KnowledgeNode node;
  final study.RetrievalItem item;
}

/// One discourse prompt (proposal-2 §6: construction-and-discourse). The
/// prompt travels IN the course file, so this step exists with or without
/// a Brain; it feeds no card, no revlog, no scheduler — ever.
class _DiscourseStep extends _Step {
  _DiscourseStep(this.node, this.item, this.idx);
  final study.KnowledgeNode node;
  final brain.DiscourseItem item;

  /// Position within the node's discourse list (stable field keys).
  final int idx;
}

/// One bounded study session (the donor screen on Drift): it declares its
/// size before it starts and ends on a calm screen — no infinite queue
/// exists (ADR-0003 law 3). Auto-grading only HIGHLIGHTS a suggestion; the
/// learner's tap is what drives SM-2 (the grading law). Every tap appends
/// one revlog row and upserts the card via study_core's scheduleSm2. A
/// lapse relearns in THIS session, with its inputs cleared.
class StudySessionScreen extends StatefulWidget {
  const StudySessionScreen(
      {super.key,
      required this.db,
      required this.courseRowId,
      required this.course,
      this.brainStore});
  final AppDatabase db;
  final int courseRowId;
  final study.Course course;

  /// The Brain settings behind the critique affordances. Tests inject
  /// in-memory secrets + a FakeBrain; null means the production store,
  /// which degrades to "no brain" wherever secure storage cannot be read
  /// — a session must never depend on the brain to run.
  final BrainStore? brainStore;

  @override
  State<StudySessionScreen> createState() => _StudySessionScreenState();
}

class _StudySessionScreenState extends State<StudySessionScreen> {
  late final int _today;
  Map<String, study.CardState>? _cards;
  List<_Step>? _steps;
  int _declaredItems = 0;
  int _declaredConcepts = 0;
  int _declaredPrompts = 0;
  bool _begun = false;
  final Map<String, TextEditingController> _ctls = {};
  int _i = 0;
  bool _revealed = false;
  int? _chosen;
  int _reviewed = 0;

  /// Who distilled this course, read from the stored raw JSON's rider
  /// (shown on the session door). The discourse prompts from the same
  /// rider live inside the step queue itself.
  brain.Provenance? _provenance;

  /// Whether a Brain tier is pinned — gates the critique affordances only;
  /// with false, this screen is exactly the brainless session.
  bool _brainEnabled = false;
  BrainStore? _defaultStore;
  BrainStore get _brainStore =>
      widget.brainStore ?? (_defaultStore ??= BrainStore.production());

  /// The current step's critique exchange (reset on advance). Suggestion
  /// only — nothing here can reach the scheduler.
  brain.SuggestedGrading? _critique;
  String? _critiqueError;
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    // One authoritative day + one card load for the whole session.
    _today = epochDayUtcNow();
    _load();
  }

  Future<void> _load() async {
    final cards = await widget.db.studyDao.loadCardStates(widget.courseRowId);
    // The raw course text carries what the parsed Course deliberately
    // ignores: the discourse prompts and the provenance stamp.
    final row = await (widget.db.select(widget.db.courses)
          ..where((c) => c.id.equals(widget.courseRowId)))
        .getSingleOrNull();
    var discourse = <String, List<brain.DiscourseItem>>{};
    brain.Provenance? provenance;
    if (row != null) {
      try {
        final decoded = jsonDecode(row.raw);
        if (decoded is Map<String, dynamic>) {
          discourse = brain.readCourseDiscourse(decoded);
          final p = decoded['provenance'];
          if (p is Map<String, dynamic>) {
            provenance = brain.Provenance.fromJson(p);
          }
        }
      } on FormatException {
        // Import validated the course itself; a malformed rider must not
        // take the session down — it simply doesn't ride.
        discourse = const {};
        provenance = null;
      }
    }
    final selection = await _brainStore.selection();
    final steps = _buildQueue(cards, _today, discourse);
    if (!mounted) return;
    setState(() {
      _cards = cards;
      _provenance = provenance;
      _brainEnabled = selection.brainEnabled;
      _steps = steps;
      _declaredItems = steps.whereType<_ItemStep>().length;
      _declaredConcepts = steps.whereType<_IntakeStep>().length;
      _declaredPrompts = steps.whereType<_DiscourseStep>().length;
    });
  }

  @override
  void dispose() {
    for (final c in _ctls.values) {
      c.dispose();
    }
    super.dispose();
  }

  List<_Step> _buildQueue(Map<String, study.CardState> cards, int today,
      Map<String, List<brain.DiscourseItem>> discourse) {
    final steps = <_Step>[];
    for (final node in widget.course.nodes) {
      // Lock only first exposure: a node already started stays available, so
      // a lapse on a prerequisite never buries reviews the learner owns.
      final started = node.items.any((it) => cards[it.id] != null);
      if (!started &&
          !study.nodeUnlocked(node, widget.course, cards, today)) {
        continue;
      }
      final due = node.items.where((it) {
        final c = cards[it.id];
        return c == null || c.isDue(today);
      }).toList();
      if (due.isEmpty) continue;
      steps.add(_IntakeStep(node));
      // Discourse rides between reading and retrieval ("after intake,
      // teach it back" — proposal-2 §6). Courses without the rider are
      // untouched: no prompts, no steps, the session exactly as today.
      final prompts = discourse[node.id] ?? const [];
      for (var d = 0; d < prompts.length; d++) {
        steps.add(_DiscourseStep(node, prompts[d], d));
      }
      for (final it in due) {
        steps.add(_ItemStep(node, it));
      }
    }
    return steps;
  }

  TextEditingController _ctl(String key) =>
      _ctls.putIfAbsent(key, () => TextEditingController());

  /// Blanks every response field belonging to [item] — one per cloze blank,
  /// or the single free-recall box.
  void _clearResponses(study.RetrievalItem item) {
    for (final entry in _ctls.entries) {
      if (entry.key.startsWith('${item.id}:')) entry.value.clear();
    }
  }

  void _advance() {
    setState(() {
      _i++;
      _revealed = false;
      _chosen = null;
      _critique = null;
      _critiqueError = null;
      _asking = false;
    });
  }

  // ---- the critique exchange (suggestion-only, consent-gated) --------------

  /// Asks the pinned Brain for a rubric-anchored critique. The button tap
  /// is the gesture (ADR-0003 law 4); a cloud tier passes THE consent
  /// chokepoint first (law 6). Whatever comes back is a suggestion — this
  /// method cannot reach the scheduler, and neither can its caller except
  /// through the learner's own grade tap.
  Future<void> _requestCritique(
      {required String rubric,
      required String question,
      required String answer}) async {
    if (_asking) return;
    setState(() {
      _asking = true;
      _critiqueError = null;
    });
    try {
      final use = await _brainStore.brainForUse();
      if (!mounted) return;
      switch (use) {
        case BrainNotConfigured(:final message):
          setState(() => _critiqueError = message);
        case BrainReady():
          if (use.requiresEgressConsent) {
            final ok = await confirmDownload(context, items: [
              DownloadItem(
                  'Send this prompt and your answer to ${use.egressHost} '
                  'for a critique — the reply size is unknown until it '
                  'arrives'),
            ]);
            if (!ok || !mounted) return;
          }
          final grading = await brain.DiscourseGrader(
                  brain: use.brain, provenance: use.provenance)
              .gradeFreeRecall(
                  rubric: rubric,
                  question: question,
                  answer: answer,
                  userGesture: const brain.UserGesture());
          if (!mounted) return;
          setState(() => _critique = grading);
      }
    } on brain.GradeSuggestionFailedException catch (e) {
      if (mounted) setState(() => _critiqueError = e.message);
    } on brain.AskException catch (e) {
      if (mounted) setState(() => _critiqueError = e.message);
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  /// The critique block shared by discourse steps and free-recall items:
  /// the model's words, its read, and who wrote it — nothing tappable.
  List<Widget> _critiqueDisplay() {
    final theme = Theme.of(context);
    final critique = _critique;
    final error = _critiqueError;
    return [
      if (critique != null) ...[
        const SizedBox(height: 12),
        _AnswerBox(
            label: critiqueByLine(critique.provenance),
            body: '${critique.critique}\n\n'
                'The model\'s read: ${critique.suggestedGrade.name} — '
                'that call stays yours.'),
      ],
      if (error != null) ...[
        const SizedBox(height: 12),
        Text(error,
            key: const Key('critique-error'),
            style: theme.textTheme.bodyMedium),
      ],
    ];
  }

  Future<void> _grade(study.RetrievalItem item, study.Grade g) async {
    final node = switch (_steps![_i]) {
      _ItemStep(:final node) => node,
      _ => null,
    };
    final card = _cards![item.id] ??
        study.CardState.initial(item.id, widget.course.srsDefaults, _today);
    final next = study.scheduleSm2(card, g, _today,
        firstIntervalDays: widget.course.srsDefaults.firstIntervalDays);
    // The grade appends to the revlog and upserts the card atomically —
    // awaited, so what the screen shows is what the database holds.
    await widget.db.studyDao.recordGrade(
        courseRowId: widget.courseRowId,
        before: card,
        after: next,
        grade: g,
        tsMs: DateTime.now().millisecondsSinceEpoch);
    _cards![item.id] = next;
    // A lapse ("Again") sets the card due today — relearn it in THIS
    // session by re-queuing it at the end, with the failed attempt cleared
    // so the learner recalls, not re-reads.
    if (node != null && next.isDue(_today)) {
      _steps!.add(_ItemStep(node, item));
      _clearResponses(item);
    }
    _reviewed++;
    if (!mounted) return;
    _advance();
  }

  @override
  Widget build(BuildContext context) {
    final steps = _steps;
    if (steps == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.course.title)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (steps.isEmpty) return _restScreen();
    if (!_begun) return _declarationScreen();
    if (_i >= steps.length) return _doneScreen();

    final step = steps[_i];
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.course.title),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(
              value: (_i + 1) / steps.length, minHeight: 4),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: switch (step) {
            _IntakeStep(:final node) => _buildIntake(node),
            _DiscourseStep() => _buildDiscourse(step),
            _ItemStep(:final node, :final item) => _buildItem(node, item),
          },
        ),
      ),
    );
  }

  /// Nothing due: an honest rest, not a nudge to do more (ADR-0003 law 5).
  Widget _restScreen() {
    return Scaffold(
      appBar: AppBar(title: Text(widget.course.title)),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.spa_outlined, size: 56),
              const SizedBox(height: 12),
              Text('Nothing due right now',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center),
              const SizedBox(height: 8),
              const Text('The ladder rests until a card ripens.',
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Done')),
            ],
          ),
        ),
      ),
    );
  }

  /// The session names its size before it starts — the bounded-session law
  /// (ADR-0003 law 3). Nothing is graded by looking at this door. A
  /// distilled course also says who thought (provenance, proposal-2 §7).
  Widget _declarationScreen() {
    final theme = Theme.of(context);
    final items = '$_declaredItems item${_declaredItems == 1 ? '' : 's'}';
    final concepts =
        '$_declaredConcepts concept${_declaredConcepts == 1 ? '' : 's'}';
    final prompts = _declaredPrompts == 0
        ? ''
        : ' · $_declaredPrompts prompt${_declaredPrompts == 1 ? '' : 's'}';
    final provenance = _provenance;
    return Scaffold(
      appBar: AppBar(title: Text(widget.course.title)),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('This session',
                    style: theme.textTheme.labelMedium,
                    textAlign: TextAlign.center),
                const SizedBox(height: 4),
                Text('$items · $concepts$prompts',
                    style: theme.textTheme.headlineSmall,
                    textAlign: TextAlign.center),
                if (provenance != null) ...[
                  const SizedBox(height: 4),
                  Text(distilledByLine(provenance),
                      key: const Key('course-provenance'),
                      style: theme.textTheme.bodySmall,
                      textAlign: TextAlign.center),
                ],
                const SizedBox(height: 8),
                Text('It ends when these are done — the queue never grows '
                    'behind your back.',
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center),
                const SizedBox(height: 24),
                FilledButton(
                    key: const Key('begin-session'),
                    onPressed: () => setState(() => _begun = true),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Begin'),
                    )),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The calm end (ADR-0003 laws 3 + 5): what was built, and a door out.
  Widget _doneScreen() {
    return Scaffold(
      appBar: AppBar(title: const Text('Session complete')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.eco_outlined, size: 56),
              const SizedBox(height: 12),
              Text('You reviewed $_reviewed item${_reviewed == 1 ? '' : 's'}.',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Done')),
            ],
          ),
        ),
      ),
    );
  }

  // ---- intake --------------------------------------------------------------

  // Split an intake passage into paragraph blocks once per node so the
  // reading surface lays them out lazily.
  final _blockCache = <String, List<String>>{};
  List<String> _intakeBlocks(study.KnowledgeNode node) =>
      _blockCache.putIfAbsent(node.id, () {
        final parts = node.intake
            .split(RegExp(r'\n[ \t]*\n'))
            .map((b) => b.trim())
            .where((b) => b.isNotEmpty)
            .toList();
        return parts.isEmpty ? [node.intake] : parts;
      });

  Widget _buildIntake(study.KnowledgeNode node) {
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
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView.builder(
            itemCount: headers.length + blocks.length,
            itemBuilder: (context, i) {
              if (i < headers.length) return headers[i];
              return Card(
                color: theme.colorScheme.surfaceContainerHighest,
                margin: const EdgeInsets.only(bottom: 8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(blocks[i - headers.length]),
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

  // ---- discourse (proposal-2 §6: construction; never scheduled) ------------

  /// One discourse prompt: write, optionally ask the pinned Brain for a
  /// critique, move on. No grade buttons exist here — there is no card,
  /// and nothing on this surface can reach the scheduler.
  Widget _buildDiscourse(_DiscourseStep step) {
    final theme = Theme.of(context);
    final controller = _ctl('${step.node.id}:d${step.idx}');
    final headline = switch (step.item.kind) {
      brain.DiscourseKind.socratic => 'Go deeper',
      brain.DiscourseKind.explainBack => 'Teach it back',
    };
    return ListView(
      children: [
        Text(headline, style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        Text(step.item.prompt, style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        TextField(
          key: Key('discourse-${step.node.id}-${step.idx}'),
          controller: controller,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'In your own words…',
          ),
        ),
        ..._critiqueDisplay(),
        const SizedBox(height: 16),
        if (_brainEnabled && _critique == null && _critiqueError == null)
          OutlinedButton.icon(
            key: const Key('discourse-critique'),
            onPressed: _asking
                ? null
                : () => _requestCritique(
                    // The node's own intake is the ground the prompt
                    // probes — the critique anchors there.
                    rubric: step.node.intake,
                    question: step.item.prompt,
                    answer: controller.text),
            icon: const Icon(Icons.psychology_outlined),
            label: const Text('Ask for a critique'),
          ),
        const SizedBox(height: 8),
        FilledButton(
          key: const Key('discourse-continue'),
          onPressed: _advance,
          child: const Text('Continue'),
        ),
      ],
    );
  }

  // ---- item scaffold -------------------------------------------------------

  Widget _buildItem(study.KnowledgeNode node, study.RetrievalItem item) {
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
            // Flexible, not rigid: at large text scales the chip yields and
            // ellipsizes instead of overflowing the row (the fleet's
            // recurring 320dp wound).
            Flexible(child: _RungChip(rung: item.rung)),
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
          study.ClozeItem() => _cloze(item),
          study.QaItem() => _qa(item),
          study.DiscriminationItem() => _discrimination(item),
          study.ProcedureItem() => _procedure(item),
        },
        if (_revealed && item.sources.isNotEmpty) ...[
          const SizedBox(height: 12),
          _AnswerBox(label: 'Sources', body: item.sources.join('\n')),
        ],
      ],
    );
  }

  // ---- cloze ---------------------------------------------------------------

  Widget _cloze(study.ClozeItem item) {
    final theme = Theme.of(context);
    final keys = study.clozeKeysInTextOrder(item.text, item.answers.keys);
    final display = item.text.replaceAll(_clozeRe, '  ____  ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(display, style: theme.textTheme.titleLarge),
        const SizedBox(height: 16),
        for (var j = 0; j < keys.length; j++) _clozeBlank(item, keys[j], j),
        if (_revealed) ...[
          const SizedBox(height: 8),
          for (final k in keys) Text('• $k: ${item.answers[k]}'),
        ],
        const SizedBox(height: 16),
        if (!_revealed)
          FilledButton(
            onPressed: () => setState(() => _revealed = true),
            child: const Text('Check'),
          )
        else
          _grades(item,
              suggestion:
                  _clozeAuto(item) ? study.Grade.good : study.Grade.again),
      ],
    );
  }

  bool _clozeAuto(study.ClozeItem item) {
    final responses = {
      for (final k in item.answers.keys) k: _ctl('${item.id}:$k').text
    };
    return study.gradeCloze(item, responses);
  }

  Widget _clozeBlank(study.ClozeItem item, String key, int index) {
    final theme = Theme.of(context);
    final controller = _ctl('${item.id}:$key');
    final correct = study.normalizeAnswer(controller.text) ==
        study.normalizeAnswer(item.answers[key]!);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        key: Key('blank-${item.id}-$key'),
        controller: controller,
        enabled: !_revealed,
        decoration: InputDecoration(
          labelText: 'Blank ${index + 1}',
          border: const OutlineInputBorder(),
          suffixIcon: !_revealed
              ? null
              : Icon(
                  correct ? Icons.check_circle : Icons.cancel,
                  color: correct
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                ),
        ),
      ),
    );
  }

  // ---- free recall (qa / procedure share one scaffold) ---------------------

  Widget _qa(study.QaItem item) => _freeRecall(
        item: item,
        prompt: item.prompt,
        hintText: 'Recall it in your own words…',
        revealLabel: 'Reveal answer',
        rubric: item.rubric,
        critiqueRubric: item.rubric ?? 'Model answer: ${item.answer}',
        reveal: [_AnswerBox(label: 'Answer', body: item.answer)],
        suggestion: study.suggestFreeRecallGrade(
            item.acceptable, _ctl('${item.id}:a').text),
      );

  Widget _procedure(study.ProcedureItem item) {
    final theme = Theme.of(context);
    return _freeRecall(
      item: item,
      prompt: item.prompt,
      hintText: 'Recall / perform the steps…',
      revealLabel: 'Reveal steps',
      rubric: item.rubric,
      critiqueRubric: item.rubric ??
          'The steps, in order:\n${[
            for (var s = 0; s < item.steps.length; s++)
              '${s + 1}. ${item.steps[s]}'
          ].join('\n')}',
      suggestion:
          study.suggestFreeRecallGrade(const [], _ctl('${item.id}:a').text),
      reveal: [
        Text('Steps', style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        for (var s = 0; s < item.steps.length; s++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('${s + 1}. ${item.steps[s]}'),
          ),
      ],
    );
  }

  Widget _freeRecall({
    required study.RetrievalItem item,
    required String prompt,
    required String hintText,
    required String revealLabel,
    required List<Widget> reveal,
    required study.Grade suggestion,
    required String critiqueRubric,
    String? rubric,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(prompt, style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        TextField(
          key: Key('recall-${item.id}'),
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
          ..._critiqueDisplay(),
          if (_brainEnabled &&
              _critique == null &&
              _critiqueError == null) ...[
            const SizedBox(height: 12),
            // The model may SUGGEST a grading of free recall; the tap
            // below stays the only road to the scheduler.
            OutlinedButton.icon(
              key: const Key('brain-suggest'),
              onPressed: _asking
                  ? null
                  : () => _requestCritique(
                      rubric: critiqueRubric,
                      question: prompt,
                      answer: _ctl('${item.id}:a').text),
              icon: const Icon(Icons.psychology_outlined),
              label: const Text('Suggest a grade'),
            ),
          ],
        ],
        const SizedBox(height: 16),
        if (!_revealed)
          FilledButton(
            onPressed: () => setState(() => _revealed = true),
            child: Text(revealLabel),
          )
        else
          // A critique's suggestion outranks keyword coverage as the
          // HIGHLIGHT — and is exactly as powerless: every button stays
          // equally tappable, only the tap reaches SM-2.
          _grades(item,
              suggestion: _critique?.suggestedGrade ?? suggestion),
      ],
    );
  }

  // ---- discrimination ------------------------------------------------------

  Widget _discrimination(study.DiscriminationItem item) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(item.prompt, style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        RadioGroup<int>(
          groupValue: _chosen,
          onChanged: (v) {
            if (!_revealed) setState(() => _chosen = v);
          },
          child: Column(
            children: [
              for (var k = 0; k < item.choices.length; k++)
                Card(
                  color: !_revealed
                      ? null
                      : (k == item.correctIndex
                          ? theme.colorScheme.primaryContainer
                          : (k == _chosen
                              ? theme.colorScheme.errorContainer
                              : null)),
                  child: RadioListTile<int>(
                    value: k,
                    enabled: !_revealed,
                    title: Text(item.choices[k]),
                  ),
                ),
            ],
          ),
        ),
        if (_revealed && item.explanation != null) ...[
          const SizedBox(height: 8),
          _AnswerBox(label: 'Why', body: item.explanation!),
        ],
        const SizedBox(height: 16),
        if (!_revealed)
          FilledButton(
            onPressed:
                _chosen == null ? null : () => setState(() => _revealed = true),
            child: const Text('Check'),
          )
        else
          _grades(
            item,
            suggestion: study.gradeDiscrimination(item, _chosen ?? -1)
                ? study.Grade.good
                : study.Grade.again,
          ),
      ],
    );
  }

  // ---- shared grade row ----------------------------------------------------

  /// The four self-rating buttons. The suggestion is FILLED, the rest are
  /// outlined — a highlight, never a decision: every button stays equally
  /// tappable, and only the tap reaches the scheduler.
  Widget _grades(study.RetrievalItem item,
      {required study.Grade suggestion}) {
    Widget b(study.Grade g, String label) => g == suggestion
        ? FilledButton(onPressed: () => _grade(item, g), child: Text(label))
        : OutlinedButton(onPressed: () => _grade(item, g), child: Text(label));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('How did that go?',
            style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 6),
        LayoutBuilder(builder: (context, constraints) {
          final buttons = [
            b(study.Grade.again, 'Again'),
            b(study.Grade.hard, 'Hard'),
            b(study.Grade.good, 'Good'),
            b(study.Grade.easy, 'Easy'),
          ];
          // Four across needs room; on a narrow phone at large text the row
          // folds to a 2×2 grid instead of shrinking the labels.
          if (constraints.maxWidth < 380) {
            return Column(
              children: [
                Row(children: [
                  Expanded(child: buttons[0]),
                  const SizedBox(width: 8),
                  Expanded(child: buttons[1]),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: buttons[2]),
                  const SizedBox(width: 8),
                  Expanded(child: buttons[3]),
                ]),
              ],
            );
          }
          return Row(
            children: [
              for (final w in buttons)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: w,
                  ),
                ),
            ],
          );
        }),
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
      label: Text('rung $rung · ${labels[rung] ?? ''}',
          maxLines: 1, overflow: TextOverflow.ellipsis),
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
          Text(body),
        ],
      ),
    );
  }
}
