/// The boot guard — 1.4.0's lesson turned into a rule.
///
/// `main()` awaits several things before `runApp()`: the media session, the
/// device stack. Each belongs to one feature, but all of them are on the
/// critical path to the *first frame*. When `JustAudioBackground.init()`
/// threw (a host-activity misconfiguration, see MainActivity.kt), the throw
/// propagated out of `main()`, `runApp()` never ran, and Android went on
/// showing `@style/LaunchTheme` — the launch logo — with no error, no
/// crash dialog, and nothing on screen to explain it. An app that cannot
/// paint is worse than an app missing lock-screen controls.
///
/// So: a boot step may fail. It may not take the boot with it, and it may
/// not fail silently.
library;

import 'package:flutter/material.dart';

/// Runs [run], returning its value; on ANY throw returns [orElse] instead
/// and appends a human-readable line to [notes] naming [what] and the real
/// cause.
///
/// [run] is invoked inside the try, so a synchronous throw before the
/// function's first await is caught as well — which is the shape a platform
/// channel actually fails in.
///
/// **[orElse] must not throw.** It is the floor; there is no T to invent if
/// it fails, so its error propagates and boot is lost again — which is the
/// very failure this function exists to prevent. That obligation is not a
/// wish: the fallbacks actually used here are constructed in the bootstrap
/// pair and pinned by tests on both tiers (the web one exists precisely
/// because `DeviceServices.detached()` throws under dart2js). If it does
/// throw anyway, BOTH causes are recorded before rethrowing — otherwise
/// whoever reads logcat sees the fallback's error and never the real one.
Future<T> bestEffort<T>({
  required String what,
  required Future<T> Function() run,
  required T Function() orElse,
  required List<String> notes,
}) async {
  try {
    return await run();
  } catch (error, stack) {
    notes.add('$what unavailable: $error');
    // Loud in the logs, always — the note is for the person holding the
    // phone, this is for whoever reads logcat afterwards.
    FlutterError.reportError(FlutterErrorDetails(
      exception: error,
      stack: stack,
      library: 'trellis boot',
      context: ErrorDescription('starting $what'),
    ));
    try {
      return orElse();
    } catch (fallbackError, fallbackStack) {
      notes.add('$what fallback also failed: $fallbackError');
      FlutterError.reportError(FlutterErrorDetails(
        exception: fallbackError,
        stack: fallbackStack,
        library: 'trellis boot',
        context: ErrorDescription('falling back for $what after: $error'),
      ));
      rethrow;
    }
  }
}

/// Shows whatever the boot could not bring up, above [child], without
/// getting in the way of using the app. Renders [child] untouched when
/// [notes] is empty, which is the ordinary case.
class BootNotice extends StatefulWidget {
  final List<String> notes;
  final Widget child;

  const BootNotice({super.key, required this.notes, required this.child});

  @override
  State<BootNotice> createState() => _BootNoticeState();
}

class _BootNoticeState extends State<BootNotice> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (widget.notes.isEmpty || _dismissed) return widget.child;
    return Column(
      children: [
        // The banner sits above the app's own Scaffolds, so it owns the
        // status-bar inset itself and carries its own Material (there is
        // no Scaffold above it to provide either).
        Material(
          child: SafeArea(
            bottom: false,
            child: MaterialBanner(
              content: Text(
                widget.notes.length == 1
                    ? widget.notes.single
                    : widget.notes.map((n) => '• $n').join('\n'),
              ),
              leading: const Icon(Icons.warning_amber_outlined),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _dismissed = true),
                  child: const Text('Dismiss'),
                ),
              ],
            ),
          ),
        ),
        Expanded(child: widget.child),
      ],
    );
  }
}
