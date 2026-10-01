/// A browser can't run anything after its tab is gone, so there is no
/// background check on the web build.
library;

import 'feed_check_settings.dart';

FeedCheckScheduler createFeedCheckScheduler() =>
    const UnavailableFeedCheckScheduler();

Future<void Function()> openFeedCheckHost(
        Future<bool> Function(FeedCheckTask task, StopSignal stop)
            runTask) async =>
    () {};

Future<void> runFeedCheckWorker(List<String> args) async {}
