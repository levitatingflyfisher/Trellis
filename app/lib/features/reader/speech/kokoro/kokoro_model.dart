/// Opens Kokoro's ONNX model and loads its Chinese front end (ADR-0007's conditional-export pattern): the
/// real one on the native tier, a refusal on the web, which has no
/// neural voice and must not pull the ONNX plugin into its bundle.
library;

export 'src/kokoro_onnx.dart'
    if (dart.library.js_interop) 'src/kokoro_onnx_unsupported.dart';
