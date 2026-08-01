/// The platform bootstrap seam (the anki_export trio pattern): main() calls
/// createDb()/createServices()/createFetcher()/databaseFile()/
/// initAudioBackground() and never touches dart:io, path_provider, or
/// drift's web options itself — native platforms resolve to the IO
/// wiring, the web build to web-safe wiring (drift-on-wasm, no isolates,
/// no ffmpeg, no Directory.systemTemp).
///
/// Both sides export the same five names; the web tier is honest about
/// what it cannot do (proposal-2 §1: full reader/feeds/study/courses/
/// backup, NO local ML — and, as of Campaign 9 Phase 2e, no lock-screen
/// media session either: [initAudioBackground] is a real call natively, a
/// no-op here).
library;

export 'bootstrap_io.dart'
    if (dart.library.js_interop) 'bootstrap_web.dart';
