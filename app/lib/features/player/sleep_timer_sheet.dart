import 'package:flutter/material.dart';

import 'player_controller.dart';
import 'sleep_timer.dart';

/// The sleep timer's own small settings surface, opened from the mini
/// player bar: durations, "end of episode", and — once one is armed — the
/// remaining time and a cancel button in the SAME sheet, so wherever you
/// set it is where you go to check or cancel it.
class SleepTimerSheet extends StatelessWidget {
  final PlayerController controller;
  const SleepTimerSheet({super.key, required this.controller});

  static const _durationsMin = [15, 30, 45, 60];

  Future<void> _custom(BuildContext context) async {
    final minutes = await showDialog<int>(
      context: context,
      builder: (_) => const _CustomMinutesDialog(),
    );
    if (minutes == null || !context.mounted) return;
    controller.startSleepTimer(duration: Duration(minutes: minutes));
    Navigator.of(context).pop();
  }

  void _pickDuration(BuildContext context, int minutes) {
    controller.startSleepTimer(duration: Duration(minutes: minutes));
    Navigator.of(context).pop();
  }

  void _endOfEpisode(BuildContext context) {
    controller.startSleepTimer();
    Navigator.of(context).pop();
  }

  void _cancel(BuildContext context) {
    controller.cancelSleepTimer();
    Navigator.of(context).pop();
  }

  static String _remainingLabel(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final mode = controller.sleepTimerMode;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Sleep timer', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 16),
                if (mode != null)
                  ..._activeContent(context, mode)
                else
                  ..._pickerContent(context),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _activeContent(BuildContext context, SleepTimerMode mode) {
    final remaining = controller.sleepTimerRemaining ?? Duration.zero;
    return [
      Text(
        mode == SleepTimerMode.endOfEpisode
            ? 'Stopping at the end of this episode.'
            : 'Stopping in ${_remainingLabel(remaining)}.',
        style: Theme.of(context).textTheme.bodyLarge,
      ),
      const SizedBox(height: 16),
      if (mode == SleepTimerMode.duration) ...[
        SizedBox(
          height: 48,
          child: OutlinedButton(
            key: const Key('sleep-timer-extend'),
            onPressed: controller.extendSleepTimer,
            child: const Text('+10 minutes'),
          ),
        ),
        const SizedBox(height: 8),
      ],
      SizedBox(
        height: 48,
        child: FilledButton(
          key: const Key('sleep-timer-cancel'),
          onPressed: () => _cancel(context),
          child: const Text('Cancel timer'),
        ),
      ),
    ];
  }

  List<Widget> _pickerContent(BuildContext context) {
    return [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final m in _durationsMin)
            SizedBox(
              width: 100,
              height: 48,
              child: OutlinedButton(
                key: Key('sleep-timer-$m'),
                onPressed: () => _pickDuration(context, m),
                child: Text('$m min'),
              ),
            ),
          SizedBox(
            width: 100,
            height: 48,
            child: OutlinedButton(
              key: const Key('sleep-timer-custom'),
              onPressed: () => _custom(context),
              child: const Text('Custom...'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      SizedBox(
        height: 48,
        child: FilledButton.tonal(
          key: const Key('sleep-timer-end-of-episode'),
          onPressed: () => _endOfEpisode(context),
          child: const Text('Stop at the end of this episode'),
        ),
      ),
    ];
  }
}

class _CustomMinutesDialog extends StatefulWidget {
  const _CustomMinutesDialog();

  @override
  State<_CustomMinutesDialog> createState() => _CustomMinutesDialogState();
}

class _CustomMinutesDialogState extends State<_CustomMinutesDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Minutes'),
      content: TextField(
        key: const Key('sleep-timer-custom-minutes'),
        controller: _controller,
        keyboardType: TextInputType.number,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'e.g. 22'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('sleep-timer-custom-confirm'),
          onPressed: () {
            final minutes = int.tryParse(_controller.text.trim());
            Navigator.of(context)
                .pop(minutes != null && minutes > 0 ? minutes : null);
          },
          child: const Text('Set'),
        ),
      ],
    );
  }
}
