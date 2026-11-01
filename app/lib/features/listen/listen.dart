/// The one door to "Listen in your language" (1.6.x). Everything outside
/// this folder comes through here.
///
/// The web build has no transcription, translation or voice, so the
/// feature can never run there; compiled in anyway, it and the ffmpeg
/// bindings it pulls in were about 38 KB of code no browser could reach.
/// The web gets a stand-in (`listen_unsupported.dart`) with the same
/// names and nothing behind them. The real files stay the DEFAULT
/// branch, as whisper_ffi's do: the analyzer only resolves defaults.
library;

export 'listen_native.dart'
    if (dart.library.js_interop) 'listen_unsupported.dart';
