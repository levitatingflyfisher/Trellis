/// The background feed check's platform seam (the bootstrap trio pattern):
/// Android gets WorkManager, the web build gets a scheduler that is never
/// available, so its settings are hidden and nothing imports the plugin.
library;

export 'feed_check_platform_io.dart'
    if (dart.library.js_interop) 'feed_check_platform_web.dart';
