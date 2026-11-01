/// The page to make or change one card by hand: front and back, or a
/// cloze written the Anki way (`{{c1::answer}}`). What is saved goes
/// through [CardEditorScreen.onSave], which writes the course text (see
/// card_store.dart); a sentence it refuses with is shown here, and the
/// page stays open.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../shared/capped_body.dart';
import 'card_editing.dart';
import 'card_images.dart';

class CardEditorScreen extends StatefulWidget {
  const CardEditorScreen({
    super.key,
    required this.title,
    required this.onSave,
    this.initial,
    this.steps = const [],
    this.stepId,
    this.onDelete,
    this.pictures,
  });

  /// Where a picture for the card is picked and kept; null shows no
  /// picture controls.
  final CardPictures? pictures;

  /// "Add card" or "Edit card".
  final String title;
  final CardDraft? initial;

  /// The course's steps, to choose where a new card goes; offered only
  /// when there is more than one.
  final List<({String id, String title})> steps;
  final String? stepId;

  /// Writes the card. A [FormatException] or [StateError] it throws is
  /// shown as its message, and nothing is closed.
  final Future<void> Function(CardDraft draft, String? stepId) onSave;

  /// Null where the card cannot be deleted from here.
  final Future<void> Function()? onDelete;

  @override
  State<CardEditorScreen> createState() => _CardEditorScreenState();
}

class _CardEditorScreenState extends State<CardEditorScreen> {
  late CardKind _kind = widget.initial?.kind ?? CardKind.frontBack;
  late final _front = TextEditingController(
      text: widget.initial?.kind == CardKind.frontBack
          ? widget.initial!.front
          : '');
  late final _back = TextEditingController(text: widget.initial?.back ?? '');
  late final _cloze = TextEditingController(
      text:
          widget.initial?.kind == CardKind.cloze ? widget.initial!.front : '');
  late String? _step = widget.stepId ??
      (widget.steps.isEmpty ? null : widget.steps.first.id);
  String? _error;
  bool _saving = false;

  /// The card's picture, by name, and its bytes once read.
  late String? _image = widget.initial?.image;
  Uint8List? _imageBytes;

  @override
  void initState() {
    super.initState();
    final name = _image;
    if (name != null) {
      widget.pictures?.load(name).then((bytes) {
        if (mounted && _image == name) setState(() => _imageBytes = bytes);
      });
    }
  }

  Future<void> _pickPicture() async {
    final pictures = widget.pictures!;
    final bytes = await pictures.pick();
    if (bytes == null || !mounted) return;
    try {
      final name = await pictures.keep(bytes);
      if (!mounted) return;
      setState(() {
        _image = name;
        _imageBytes = bytes;
        _error = null;
      });
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  void _removePicture() => setState(() {
        _image = null;
        _imageBytes = null;
      });

  @override
  void dispose() {
    _front.dispose();
    _back.dispose();
    _cloze.dispose();
    super.dispose();
  }

  CardDraft get _draft => _kind == CardKind.cloze
      ? CardDraft.cloze(_cloze.text, image: _image)
      : CardDraft.frontBack(_front.text, _back.text, image: _image);

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(_draft, _step);
      if (mounted) Navigator.of(context).pop(true);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    } on StateError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Delete this card?'),
        content: const Text('What you have studied of it goes with it.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await widget.onDelete!();
      if (mounted) Navigator.of(context).pop(true);
    } on StateError {
      setState(() => _error = 'A step keeps at least one card. Change this '
          'one instead, or add another first.');
    }
  }

  void _blankSelection() {
    final sel = _cloze.selection;
    if (!sel.isValid || sel.isCollapsed) {
      setState(() => _error = 'Select the words to hide first.');
      return;
    }
    final text = blankSelection(_cloze.text, sel.start, sel.end);
    _cloze.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(
            offset: sel.end + (text.length - _cloze.text.length)));
    setState(() => _error = null);
  }

  /// The card's picture, shown with it on the front in a session: one to
  /// add, or the one it has, to change or take off.
  Widget _picture(ThemeData theme) {
    final bytes = _imageBytes;
    final buttonStyle =
        OutlinedButton.styleFrom(minimumSize: const Size(48, 48));
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_image != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: bytes == null
                  ? Text('This card’s picture isn’t on this device.',
                      style: theme.textTheme.bodySmall)
                  : ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 200),
                      child: Image.memory(bytes,
                          key: const Key('card-picture'),
                          semanticLabel: 'The card’s picture',
                          fit: BoxFit.contain),
                    ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Tooltip(
                message: _image == null
                    ? 'Pick a picture to show with this card'
                    : 'Pick another picture for this card',
                child: OutlinedButton.icon(
                  key: Key(_image == null
                      ? 'card-picture-add'
                      : 'card-picture-change'),
                  style: buttonStyle,
                  onPressed: _pickPicture,
                  icon: const Icon(Icons.image_outlined),
                  label: Text(
                      _image == null ? 'Add a picture' : 'Change picture'),
                ),
              ),
              if (_image != null)
                Tooltip(
                  message: 'Show no picture with this card',
                  child: OutlinedButton.icon(
                    key: const Key('card-picture-remove'),
                    style: buttonStyle,
                    onPressed: _removePicture,
                    icon: const Icon(Icons.hide_image_outlined),
                    label: const Text('Remove picture'),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          // A word on the bar, not a bare icon (fleet rule C11).
          TextButton(
            key: const Key('card-save'),
            onPressed: _saving ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: CappedBody(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SegmentedButton<CardKind>(
              key: const Key('card-kind'),
              segments: const [
                ButtonSegment(
                    value: CardKind.frontBack,
                    label: Text('Front and back'),
                    tooltip: 'A question on the front, its answer on the back'),
                ButtonSegment(
                    value: CardKind.cloze,
                    label: Text('Cloze'),
                    tooltip: 'A sentence with words hidden'),
              ],
              selected: {_kind},
              onSelectionChanged: (s) => setState(() {
                _kind = s.single;
                _error = null;
              }),
            ),
            const SizedBox(height: 16),
            if (widget.steps.length > 1) ...[
              DropdownButtonFormField<String>(
                key: const Key('card-step'),
                initialValue: _step,
                decoration: const InputDecoration(
                    labelText: 'Step', border: OutlineInputBorder()),
                items: [
                  for (final s in widget.steps)
                    DropdownMenuItem(
                        value: s.id,
                        child: Text(s.title, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => setState(() => _step = v),
              ),
              const SizedBox(height: 16),
            ],
            if (_kind == CardKind.frontBack) ...[
              TextField(
                key: const Key('card-front'),
                controller: _front,
                minLines: 2,
                maxLines: 8,
                decoration: const InputDecoration(
                    labelText: 'Front', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('card-back'),
                controller: _back,
                minLines: 2,
                maxLines: 8,
                decoration: const InputDecoration(
                    labelText: 'Back', border: OutlineInputBorder()),
              ),
            ] else ...[
              TextField(
                key: const Key('card-cloze-text'),
                controller: _cloze,
                minLines: 3,
                maxLines: 10,
                decoration: const InputDecoration(
                  labelText: 'Text',
                  helperText: 'Hide words as {{c1::word}}, the way Anki '
                      'does. Blanks with the same number are asked '
                      'together.',
                  helperMaxLines: 3,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Tooltip(
                  message: 'Hide the selected words as the next blank',
                  child: OutlinedButton.icon(
                    key: const Key('card-blank'),
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(48, 48)),
                    onPressed: _blankSelection,
                    icon: const Icon(Icons.format_strikethrough),
                    label: const Text('Hide the selection'),
                  ),
                ),
              ),
            ],
            if (widget.pictures != null) _picture(theme),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  key: const Key('card-error'),
                  style: TextStyle(color: theme.colorScheme.error)),
            ],
            if (widget.onDelete != null) ...[
              const SizedBox(height: 32),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('card-delete'),
                  style:
                      TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _delete,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete card'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Opens the editor; true when a card was saved or deleted.
Future<bool> showCardEditor(
  BuildContext context, {
  required String title,
  required Future<void> Function(CardDraft draft, String? stepId) onSave,
  CardDraft? initial,
  List<({String id, String title})> steps = const [],
  String? stepId,
  Future<void> Function()? onDelete,
  CardPictures? pictures,
}) async =>
    await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => CardEditorScreen(
            title: title,
            onSave: onSave,
            initial: initial,
            steps: steps,
            stepId: stepId,
            onDelete: onDelete,
            pictures: pictures))) ??
    false;
