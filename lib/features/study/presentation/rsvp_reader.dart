import 'dart:async';

import 'package:flutter/material.dart';

/// Optimal Recognition Point — the letter the eye should fixate on. Keeping it
/// pinned to a fixed horizontal guide is what lets the eye stay still while
/// words stream past (the core RSVP speed-reading trick).
int orpIndex(String word) {
  final n = word.length;
  if (n <= 1) return 0;
  if (n <= 5) return 1;
  if (n <= 9) return 2;
  return 3;
}

// Compiled once — dwellMultiplier runs once per streamed word (~13×/s at 800 WPM).
final _reSentenceEnd = RegExp(r'[.!?]"?$');
final _reClauseEnd = RegExp(r'[;:]$');
final _reCommaEnd = RegExp(r'[,)]$');

/// Per-word dwell multiplier — punctuation gets a longer beat so clauses and
/// sentences land.
double dwellMultiplier(String word) {
  if (_reSentenceEnd.hasMatch(word)) return 2.2;
  if (_reClauseEnd.hasMatch(word)) return 1.6;
  if (_reCommaEnd.hasMatch(word)) return 1.4;
  return word.length > 12 ? 1.3 : 1.0;
}

/// Streams `text` one word at a time with an ORP-aligned pivot, adjustable WPM,
/// play/pause/restart, and an `onComplete` callback when the passage finishes.
class RsvpReader extends StatefulWidget {
  const RsvpReader({
    super.key,
    required this.text,
    this.initialWpm = 350,
    this.onComplete,
  });

  final String text;
  final int initialWpm;
  final VoidCallback? onComplete;

  @override
  State<RsvpReader> createState() => _RsvpReaderState();
}

class _RsvpReaderState extends State<RsvpReader> {
  late final List<String> _words =
      widget.text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  int _i = 0;
  int _wpm = 350;
  bool _playing = false;
  bool _done = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _wpm = widget.initialWpm;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _scheduleNext() {
    if (!_playing) return;
    final word = _i < _words.length ? _words[_i] : '';
    final ms = (60000 / _wpm * dwellMultiplier(word)).round();
    _timer = Timer(Duration(milliseconds: ms), () {
      if (!mounted) return;
      if (_i >= _words.length - 1) {
        setState(() {
          _playing = false;
          _done = true;
        });
        widget.onComplete?.call();
        return;
      }
      setState(() => _i++);
      _scheduleNext();
    });
  }

  void _toggle() {
    if (_done) {
      setState(() {
        _i = 0;
        _done = false;
      });
    }
    setState(() => _playing = !_playing);
    if (_playing) {
      _scheduleNext();
    } else {
      _timer?.cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final word = _words.isEmpty ? '' : _words[_i.clamp(0, _words.length - 1)];
    final orp = orpIndex(word);
    final before = word.substring(0, orp);
    final pivot = word.isEmpty ? '' : word[orp];
    final after = orp + 1 <= word.length ? word.substring(orp + 1) : '';
    final mono = theme.textTheme.displaySmall?.copyWith(
      fontFeatures: const [],
      fontWeight: FontWeight.w600,
      letterSpacing: 0.5,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The display: pivot pinned to centre via flexible sides.
        Container(
          height: 132,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // centre guide
              Align(
                alignment: Alignment.topCenter,
                child: Container(width: 2, height: 14, color: theme.colorScheme.primary),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Container(width: 2, height: 14, color: theme.colorScheme.primary),
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(before,
                        textAlign: TextAlign.right, maxLines: 1, style: mono),
                  ),
                  Text(pivot,
                      style: mono?.copyWith(color: theme.colorScheme.primary)),
                  Expanded(
                    child: Text(after,
                        textAlign: TextAlign.left, maxLines: 1, style: mono),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: _words.isEmpty ? 0 : (_i + 1) / _words.length,
          minHeight: 4,
        ),
        const SizedBox(height: 4),
        Text('${_i + 1} / ${_words.length} words',
            style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton.filled(
              onPressed: _toggle,
              icon: Icon(_done
                  ? Icons.replay
                  : (_playing ? Icons.pause : Icons.play_arrow)),
            ),
          ],
        ),
        Row(
          children: [
            const Text('WPM'),
            Expanded(
              child: Slider(
                value: _wpm.toDouble(),
                min: 150,
                max: 800,
                divisions: 26,
                label: '$_wpm',
                onChanged: (v) => setState(() => _wpm = v.round()),
              ),
            ),
            SizedBox(
                width: 44,
                child: Text('$_wpm', textAlign: TextAlign.end)),
          ],
        ),
      ],
    );
  }
}
