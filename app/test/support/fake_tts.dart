/// Fake for the TtsSpeaker seam — records utterances and completes each one
/// on a fake-time timer beat, so a widget test drives speech with explicit
/// `pump(utteranceLength)` loops (the timer-paced-pipeline law) and no test
/// ever touches the platform TTS channel.
library;

import 'dart:async';

import 'package:trellis/services/device_services.dart';

class FakeTtsSpeaker implements TtsSpeaker {
  /// Every spoken (text, lang), in order.
  final List<({String text, String? lang})> utterances = [];
  final Duration utteranceLength;
  int stops = 0;
  double? rate;

  Completer<void>? _current;
  Timer? _timer;

  FakeTtsSpeaker({this.utteranceLength = const Duration(milliseconds: 100)});

  @override
  Future<void> speak(String text, {String? lang}) {
    utterances.add((text: text, lang: lang));
    final c = Completer<void>();
    _current = c;
    _timer = Timer(utteranceLength, () {
      if (!c.isCompleted) c.complete();
    });
    return c.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    _timer?.cancel();
    // A real engine fires its completion handler on stop; the awaiting
    // caller must never hang on a cancelled utterance.
    final c = _current;
    if (c != null && !c.isCompleted) c.complete();
  }

  @override
  Future<void> setRate(double r) async {
    rate = r;
  }
}
