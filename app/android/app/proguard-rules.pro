# ONNX Runtime's native library finds its Java classes (OnnxTensor,
# OrtSession, ...) by name over JNI. R8 renaming them makes FindClass return
# null and the app aborts on the first translation run (1.5.6 on a phone).
-keep class ai.onnxruntime.** { *; }
