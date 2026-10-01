/// The mini player on every screen (1.5.5, user: "I'd like the little pop
/// up of play controls to exist wherever I am in the app"). Lives in
/// `MaterialApp.builder`, under every route, so a pushed screen needs no
/// wiring of its own. The shell keeps its own bar above the tab bar on
/// the root route; this one shows whenever a page is pushed over it.
library;

import 'package:flutter/material.dart';

import 'player_controller.dart';

/// Tracks the page routes on the app's Navigator, so the host knows when
/// a page sits over the root one. Popups, dialogs and sheets are not
/// pages and never count: a ⋮ menu over the shell must not flip the bar.
class MiniPlayerRoutes extends NavigatorObserver with ChangeNotifier {
  final List<Route<dynamic>> _pages = [];

  bool get pageOverRoot => _pages.length > 1;

  void _changed() => WidgetsBinding.instance
      .addPostFrameCallback((_) => notifyListeners());

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute) {
      _pages.add(route);
      _changed();
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_pages.remove(route)) _changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_pages.remove(route)) _changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = oldRoute == null ? -1 : _pages.indexOf(oldRoute);
    if (i >= 0) _pages.removeAt(i);
    if (newRoute is PageRoute) {
      _pages.insert(i >= 0 ? i : _pages.length, newRoute);
    }
    _changed();
  }
}

class MiniPlayerHost extends StatefulWidget {
  final MiniPlayerRoutes routes;
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  const MiniPlayerHost(
      {super.key,
      required this.routes,
      required this.navigatorKey,
      required this.child});

  static MiniPlayerHostState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<MiniPlayerHostState>();

  @override
  State<MiniPlayerHost> createState() => MiniPlayerHostState();
}

class MiniPlayerHostState extends State<MiniPlayerHost> {
  PlayerController? _controller;
  WidgetBuilder? _bar;
  late final OverlayEntry _entry = OverlayEntry(builder: _layout);

  /// The shell hands over its controller and its bar (with its own
  /// callbacks, whose context sits under the Navigator).
  void attach(PlayerController controller, WidgetBuilder bar) {
    _controller = controller;
    _bar = bar;
    _rebuildSoon();
  }

  void detach(PlayerController controller) {
    if (_controller != controller) return;
    _controller = null;
    _bar = null;
    _rebuildSoon();
  }

  // The shell attaches and detaches while the tree is building.
  void _rebuildSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _entry.markNeedsBuild();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  MiniPlayerRoutes get routes => widget.routes;

  /// A context a modal sheet can open from, for the bar here, which sits
  /// above the Navigator.
  BuildContext? get navigatorContext => widget.navigatorKey.currentContext;

  @override
  void didUpdateWidget(MiniPlayerHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    _entry.markNeedsBuild();
  }

  Widget _layout(BuildContext context) {
    final controller = _controller;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.routes, ?controller]),
      builder: (context, _) {
        final bar = _bar;
        final show = bar != null &&
            controller?.current != null &&
            widget.routes.pageOverRoot &&
            // The keyboard covers the bar anyway, and the page above
            // would shrink twice.
            MediaQuery.viewInsetsOf(context).bottom == 0;
        return Column(
          children: [
            Expanded(
              child: show
                  ? MediaQuery.removePadding(
                      context: context, removeBottom: true, child: widget.child)
                  : widget.child,
            ),
            if (show) bar(context),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) =>
      // The bar's tooltips need an Overlay, and this sits above the
      // Navigator's own.
      Overlay(initialEntries: [_entry]);
}

/// A context a modal sheet can open from: [context] itself when it is under
/// a Navigator, else the app's Navigator (the host's bar sits above it).
BuildContext sheetContextFor(BuildContext context) {
  if (Navigator.maybeOf(context) != null) return context;
  return MiniPlayerHost.maybeOf(context)?.navigatorContext ?? context;
}
