import 'dart:ffi' show Abi;

bool get isAndroidArm64 => Abi.current() == Abi.androidArm64;
