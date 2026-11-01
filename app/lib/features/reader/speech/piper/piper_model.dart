/// Opens Piper's ONNX model and loads its Russian front end (ADR-0007's
/// conditional-export pattern): the real one on the native tier, a
/// refusal on the web, which has no neural voice and must not pull the
/// ONNX plugin into its bundle.
library;

export 'src/piper_onnx.dart'
    if (dart.library.js_interop) 'src/piper_onnx_unsupported.dart';
