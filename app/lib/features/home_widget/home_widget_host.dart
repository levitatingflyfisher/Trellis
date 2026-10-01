/// The home-screen widget's door (1.5.5): the app's own small channel to
/// `android/.../WidgetBridge.kt` on Android, or nowhere (the web build,
/// other platforms, widget tests).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'widget_snapshot.dart';

/// What a tap on the widget asks of the app.
enum WidgetActionKind {
  /// Play: resumes the last-played work, loading it if need be. Sent
  /// with the app running behind the widget, or by a tap that opened it.
  play,

  /// Pause, as the card showed it; a no-op if playback already stopped.
  pause,
  back,
  forward,

  /// The art or title: the work's page.
  openWork,

  /// Continue reading: the work in the reader, at its place.
  read,
}

class WidgetAction {
  final WidgetActionKind kind;
  final int? workId;
  final int? profileId;
  const WidgetAction(this.kind, {this.workId, this.profileId});

  static WidgetAction? fromJson(Map<Object?, Object?> m) {
    final kind = WidgetActionKind.values
        .where((k) => k.name == m['kind'])
        .firstOrNull;
    if (kind == null) return null;
    final work = m['workId'];
    final profile = m['profileId'];
    return WidgetAction(
      kind,
      workId: work is int && work > 0 ? work : null,
      profileId: profile is int && profile > 0 ? profile : null,
    );
  }
}

abstract class HomeWidgetHost {
  HomeWidgetHost();

  /// Whether a widget can exist here at all; when not, nothing is written.
  bool get available;

  Future<void> push(WidgetSnapshot snapshot);

  /// Every tap waiting, oldest first; each is handed out once.
  Future<List<WidgetAction>> takePending() async => const [];

  /// Called when a tap arrives while the app is running; null stops.
  VoidCallback? onArrival;
}

class UnavailableHomeWidgetHost implements HomeWidgetHost {
  const UnavailableHomeWidgetHost();
  @override
  VoidCallback? get onArrival => null;
  @override
  set onArrival(VoidCallback? callback) {}
  @override
  Future<List<WidgetAction>> takePending() async => const [];
  @override
  bool get available => false;
  @override
  Future<void> push(WidgetSnapshot snapshot) async {}
}

HomeWidgetHost createHomeWidgetHost() =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android
    ? ChannelHomeWidgetHost()
    : const UnavailableHomeWidgetHost();

const homeWidgetChannelName = 'com.openhearth.trellis/widget';

class ChannelHomeWidgetHost extends HomeWidgetHost {
  ChannelHomeWidgetHost([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel(homeWidgetChannelName) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'actionArrived') onArrival?.call();
    });
  }

  final MethodChannel _channel;

  @override
  bool get available => true;

  @override
  Future<void> push(WidgetSnapshot snapshot) async {
    try {
      await _channel.invokeMethod<void>('update', {
        'snapshot': jsonEncode(snapshot.toJson()),
      });
    } on Exception catch (e) {
      // A widget that can't refresh is a stale card, never a crash.
      debugPrint('Widget: update failed: $e');
    }
  }

  @override
  Future<List<WidgetAction>> takePending() async {
    final raw = await _channel.invokeListMethod<Object?>('takePending');
    return [
      for (final m in raw ?? const [])
        if (m is Map) ?WidgetAction.fromJson(m),
    ];
  }
}
