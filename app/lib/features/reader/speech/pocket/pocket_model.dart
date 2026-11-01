/// Opens Pocket TTS's four ONNX graphs (ADR-0007's conditional-export
/// pattern): the real ones on the native tier, a refusal on the web,
/// which has no neural voice and must not pull the ONNX plugin in.
library;

export 'src/pocket_onnx.dart'
    if (dart.library.js_interop) 'src/pocket_onnx_unsupported.dart';
