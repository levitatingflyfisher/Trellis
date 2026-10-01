/// Where shares come from: the Android share sheet through the app's own
/// small channel (`android/.../ShareInbox.kt`), or nowhere (the web build,
/// other platforms, widget tests).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'share_intake.dart';

abstract class ShareSource {
  /// Every share waiting, oldest first; each is handed out once.
  Future<List<SharedPayload>> takePending();

  /// Called when a share arrives while the app is running; null stops.
  set onArrival(VoidCallback? callback);

  /// Deletes share copies left behind (a share refused, a process killed
  /// mid-copy), except those in [keep], which shares still wait on.
  Future<void> sweep(Set<String> keep);
}

class UnavailableShareSource implements ShareSource {
  const UnavailableShareSource();
  @override
  Future<List<SharedPayload>> takePending() async => const [];
  @override
  set onArrival(VoidCallback? callback) {}
  @override
  Future<void> sweep(Set<String> keep) async {}
}

ShareSource createShareSource() =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? ChannelShareSource()
        : const UnavailableShareSource();

const shareChannelName = 'com.openhearth.trellis/share';

class ChannelShareSource implements ShareSource {
  ChannelShareSource([MethodChannel? channel])
      : _channel = channel ?? const MethodChannel(shareChannelName) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'shareArrived') _onArrival?.call();
    });
  }

  final MethodChannel _channel;
  VoidCallback? _onArrival;

  @override
  set onArrival(VoidCallback? callback) => _onArrival = callback;

  @override
  Future<List<SharedPayload>> takePending() async {
    final raw = await _channel.invokeListMethod<Object?>('takePending');
    return [
      for (final p in raw ?? const [])
        if (p is Map) SharedPayload.fromJson(p),
    ];
  }

  @override
  Future<void> sweep(Set<String> keep) =>
      _channel.invokeMethod<void>('sweep', {'keep': keep.toList()});
}
