/// Calls into the channels MainActivity attaches (the share inbox, the
/// feed-check scheduler, the home-screen widget) only work while the
/// activity is there.
///
/// Android can start the app's engine with no activity at all: media
/// resumption after a boot starts the audio service alone, and main()
/// runs the whole start-up. A call into those channels then throws
/// MissingPluginException. When the activity comes, it attaches the
/// channels to this same engine before the app comes to the front, so
/// the call is simply made again then.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Completes the next time the app comes to the front.
///
/// A plain observer, not AppLifecycleListener: that one asserts an exact
/// sequence of states, and an engine started without an activity does not
/// follow it.
Future<void> appResumed() {
  final done = Completer<void>();
  late final _ResumeObserver observer;
  observer = _ResumeObserver(() {
    WidgetsBinding.instance.removeObserver(observer);
    if (!done.isCompleted) done.complete();
  });
  WidgetsBinding.instance.addObserver(observer);
  return done.future;
}

class _ResumeObserver with WidgetsBindingObserver {
  _ResumeObserver(this.onResumed);
  final VoidCallback onResumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onResumed();
  }
}

/// Runs [call]; while it finds no activity behind its channel, waits for
/// the app to come to the front ([resumed]) and runs it again. Nothing is
/// skipped and no error is raised for the missing activity; any other
/// failure is the caller's, as before.
Future<T> onceHostAttached<T>(Future<T> Function() call,
    {Future<void> Function() resumed = appResumed}) async {
  while (true) {
    try {
      return await call();
    } on MissingPluginException {
      await resumed();
    }
  }
}
