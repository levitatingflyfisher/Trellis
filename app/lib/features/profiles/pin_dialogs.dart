import 'package:flutter/material.dart';

import 'parent_pin.dart';

/// The honest forgotten-PIN truth, shown wherever the PIN is asked for or
/// set. There is deliberately no backdoor to soften it (P5): pretending a
/// recovery exists would make the gate a fiction.
const String kPinNoRecoveryNotice =
    'If the PIN is forgotten there is no recovery: it can only be removed '
    "with the current PIN, or by clearing the app's data. Reading is never "
    'locked.';

/// THE one PIN chokepoint. True means the door is open: either no PIN is
/// set (the PIN is optional) or the parent typed the right one. Everything
/// the PIN gates — profile create/delete/rename, the parent dashboard —
/// passes here and nowhere else.
Future<bool> requireParentPin(
    BuildContext context, ParentPinService pin) async {
  if (!await pin.isSet) return true;
  if (!context.mounted) return false;
  final ok = await showDialog<bool>(
      context: context, builder: (_) => _PinEntryDialog(pin: pin));
  return ok == true;
}

class _PinEntryDialog extends StatefulWidget {
  final ParentPinService pin;
  const _PinEntryDialog({required this.pin});

  @override
  State<_PinEntryDialog> createState() => _PinEntryDialogState();
}

class _PinEntryDialogState extends State<_PinEntryDialog> {
  final _entry = TextEditingController();
  bool _wrong = false;

  @override
  void dispose() {
    _entry.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    final ok = await widget.pin.verify(_entry.text.trim());
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _wrong = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Parent PIN'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('pin-entry'),
            controller: _entry,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            onSubmitted: (_) => _unlock(),
            decoration: InputDecoration(
                labelText: 'PIN',
                errorText: _wrong ? "That's not the PIN." : null),
          ),
          const SizedBox(height: 12),
          Text(kPinNoRecoveryNotice,
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel')),
        FilledButton(onPressed: _unlock, child: const Text('Unlock')),
      ],
    );
  }
}

/// First-time set (only offered while no PIN exists).
Future<void> showSetPinDialog(BuildContext context, ParentPinService pin) =>
    showDialog<void>(context: context, builder: (_) => _SetPinDialog(pin: pin));

class _SetPinDialog extends StatefulWidget {
  final ParentPinService pin;
  const _SetPinDialog({required this.pin});

  @override
  State<_SetPinDialog> createState() => _SetPinDialogState();
}

class _SetPinDialogState extends State<_SetPinDialog> {
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final error = validateNewPin(_next.text.trim(), _confirm.text.trim());
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    await widget.pin.enable(_next.text.trim());
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Set a parent PIN'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
              'The PIN protects profile changes and the parent dashboard — '
              'never reading or studying.',
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 12),
          TextField(
            key: const Key('pin-new'),
            controller: _next,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
                labelText: 'New PIN', errorText: _error),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('pin-confirm'),
            controller: _confirm,
            obscureText: true,
            keyboardType: TextInputType.number,
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(labelText: 'Repeat it'),
          ),
          const SizedBox(height: 12),
          Text(kPinNoRecoveryNotice,
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Set PIN')),
      ],
    );
  }
}

/// Change and remove share one dialog shape: the current PIN first (the
/// current-PIN law), then — for change — the new pair.
Future<void> showChangePinDialog(BuildContext context, ParentPinService pin) =>
    showDialog<void>(
        context: context,
        builder: (_) => _CurrentPinDialog(pin: pin, removing: false));

Future<void> showRemovePinDialog(BuildContext context, ParentPinService pin) =>
    showDialog<void>(
        context: context,
        builder: (_) => _CurrentPinDialog(pin: pin, removing: true));

class _CurrentPinDialog extends StatefulWidget {
  final ParentPinService pin;
  final bool removing;
  const _CurrentPinDialog({required this.pin, required this.removing});

  @override
  State<_CurrentPinDialog> createState() => _CurrentPinDialogState();
}

class _CurrentPinDialogState extends State<_CurrentPinDialog> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  String? _currentError;
  String? _nextError;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!widget.removing) {
      final error = validateNewPin(_next.text.trim(), _confirm.text.trim());
      if (error != null) {
        setState(() {
          _nextError = error;
          _currentError = null;
        });
        return;
      }
    }
    final ok = widget.removing
        ? await widget.pin.disable(current: _current.text.trim())
        : await widget.pin.change(
            current: _current.text.trim(), next: _next.text.trim());
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _currentError = "That's not the current PIN.";
        _nextError = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.removing ? 'Remove the PIN' : 'Change the PIN'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('pin-current'),
            controller: _current,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
                labelText: 'Current PIN', errorText: _currentError),
          ),
          if (!widget.removing) ...[
            const SizedBox(height: 8),
            TextField(
              key: const Key('pin-new'),
              controller: _next,
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                  labelText: 'New PIN', errorText: _nextError),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('pin-confirm'),
              controller: _confirm,
              obscureText: true,
              keyboardType: TextInputType.number,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(labelText: 'Repeat it'),
            ),
          ],
          const SizedBox(height: 12),
          Text(kPinNoRecoveryNotice,
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: _submit,
            child: Text(widget.removing ? 'Remove PIN' : 'Change')),
      ],
    );
  }
}

/// Null when [next] is usable and confirmed; the calm reason otherwise.
String? validateNewPin(String next, String confirm) {
  if (next.length < 4) return 'Use at least 4 characters.';
  if (next != confirm) return "The PINs don't match.";
  return null;
}
