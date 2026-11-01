/// The web's stand-in for "Listen in your language": the same names as
/// `listen_native.dart` gives, with nothing behind them. The web has no
/// engines, so its episode actions never build a chain and its episode
/// page never shows the bar; these exist so the app compiles there
/// without the real feature. `test/features/listen_web_stub_test.dart`
/// keeps the names in step.
library;

import 'package:flutter/widgets.dart';

import '../../db/database.dart';
import '../../services/device_services.dart';
import '../models/consent.dart';
import '../transcribe/transcribe_coordinator.dart';

/// Never made on the web.
class ListenChain extends ChangeNotifier {}

ListenChain deviceListenChain({
  required AppDatabase db,
  required DeviceServices services,
  required TranscribeCoordinator transcriber,
}) =>
    throw UnsupportedError('Listening in another language needs the app.');

/// No language can be saved as audio in a browser.
List<String> savableListenLanguages() => const [];

Future<List<DownloadItem>> listenDownloads({
  required AppDatabase db,
  required DeviceServices services,
  required TranscribeCoordinator transcriber,
  required Work work,
  required Episode episode,
  required String lang,
}) async =>
    const [];

/// Shows nothing: there is nothing it could start.
class ListenInLanguageBar extends StatelessWidget {
  const ListenInLanguageBar({
    super.key,
    required this.db,
    required this.chain,
    required this.work,
    required this.languages,
    required this.downloadsFor,
    required this.onPlay,
  });

  final AppDatabase db;
  final ListenChain chain;
  final Work work;
  final List<String> languages;
  final Future<List<DownloadItem>> Function(String lang) downloadsFor;
  final Future<void> Function(int spokenWorkId, {required bool justMade})
      onPlay;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
