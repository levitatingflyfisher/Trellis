/// Whether this process runs as Android arm64. dart:ffi's [Abi] answers it,
/// but the web build must never see dart:ffi, so the web side is a stub.
library;

export 'native_abi_io.dart' if (dart.library.js_interop) 'native_abi_web.dart';
