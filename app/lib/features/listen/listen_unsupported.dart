/// The web's stand-in for "Listen in your language": the names the app
/// asks `listen_native.dart` for, with nothing behind them. The web has
/// no engines, so its episode actions never build the owner of the one
/// tap, its rows get no second button and its episode page keeps two
/// ways in; these exist so the app compiles there without the real
/// feature. `test/features/listen_web_stub_test.dart`
/// keeps the names in step.
library;

import 'package:flutter/widgets.dart';

import '../../db/database.dart';
import '../../services/device_services.dart';
import '../player/player_controller.dart';
import '../transcribe/transcribe_coordinator.dart';

/// Never offered on the web.
class ListenOffer {
  const ListenOffer._();
  String? get lang => null;
  List<String> get languages => const [];
  bool get making => false;
  bool get waiting => false;
  bool get busy => false;
  bool get ready => false;
  bool get failed => false;
  double? get fraction => null;
  String get label => '';
  String get line => '';
}

/// Never made on the web: nothing there can be made, so no row and no
/// page is ever offered a button.
class ListenJobs extends ChangeNotifier {
  Future<void> get ready => Future.value();
  String? get language => null;
  Future<void> refresh() async {}
  Future<void> refreshVoices() async {}
  Future<void> resumeLine() async {}
  Future<void> stopAll() async {}
  ListenOffer? offerFor(Work work, Episode? episode, {String? feedLang}) =>
      null;
  Future<String?> pickLanguage(BuildContext context, List<String> languages,
          {({String? workLang, String? feedLang})? of,
          bool anyEpisode = false}) async =>
      null;
  Future<String?> chooseLearningLanguage(BuildContext context) async => null;
  Future<void> tap(BuildContext context, Work work, Episode episode,
      {String? feedLang}) async {}
  Future<void> makeIn(
      BuildContext context, Work work, Episode episode, String lang,
      {String? feedLang}) async {}
  void stop(int workId) {}
  Future<void> makeAheadPass() async {}
  MakeAheadOffer? aheadOfferFor(Feed feed) => null;
  String? get aheadLine => null;
  Future<void> setMakeAhead(
      BuildContext context, Feed feed, bool on) async {}
}

/// Never offered on the web: nothing there can be made ahead.
class MakeAheadOffer {
  const MakeAheadOffer._();
  bool get on => false;
  String? get lang => null;
  String? get line => null;
}

ListenJobs deviceListenJobs({
  required AppDatabase db,
  required DeviceServices services,
  required TranscribeCoordinator transcriber,
  PlayerController? player,
}) =>
    throw UnsupportedError('Listening in another language needs the app.');

/// Draws nothing: on the web a row has Play and no second button.
class ListenRowButton extends StatelessWidget {
  const ListenRowButton({
    super.key,
    required this.jobs,
    required this.work,
    required this.episode,
    this.feedLang,
  });

  final ListenJobs jobs;
  final Work work;
  final Episode episode;
  final String? feedLang;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Draws nothing: no show has the switch on the web.
class MakeAheadTile extends StatelessWidget {
  const MakeAheadTile({super.key, required this.jobs, required this.feed});

  final ListenJobs jobs;
  final Feed feed;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Draws nothing on the web.
class MakeAheadLine extends StatelessWidget {
  const MakeAheadLine({super.key, required this.jobs});

  final ListenJobs jobs;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
