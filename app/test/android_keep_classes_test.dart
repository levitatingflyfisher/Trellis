/// Release builds run R8, which renames classes. ONNX Runtime's native
/// library looks its Java classes up by name, so a renamed OnnxTensor made
/// the first translation abort the app (1.5.6 on a phone). The keep rule
/// must exist and the release build type must load it.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('R8 keeps ONNX Runtime classes by name', () {
    final rules = File('android/app/proguard-rules.pro');
    expect(rules.existsSync(), isTrue, reason: 'proguard-rules.pro missing');
    expect(rules.readAsStringSync(),
        contains('-keep class ai.onnxruntime.** { *; }'));
    expect(File('android/app/build.gradle.kts').readAsStringSync(),
        contains('"proguard-rules.pro"'));
  });
}
