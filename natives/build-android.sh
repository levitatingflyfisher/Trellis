#!/usr/bin/env bash
# Builds the arm64 libwhisper.so and places it in the app's jniLibs, where
# gradle packs it into the APK and Android's loader resolves the bare
# soname DeviceServices.whisperLibraryPath() returns.
#
# ANDROID_NDK defaults to the workshop's checked-in NDK; android-24 matches
# the app's minSdk floor for 16KB-page-safe builds.
set -euo pipefail
cd "$(dirname "$0")"

NDK="${ANDROID_NDK:-/mnt/tera/working/programming/androidDevTools/ndk/28.2.13676358}"
ABI=arm64-v8a

# The workshop has no system cmake; the Android SDK's serves both builds.
PATH="/mnt/tera/working/programming/androidDevTools/cmake/3.22.1/bin:$PATH"

cmake -B "build/android-$ABI" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$ABI" \
  -DANDROID_PLATFORM=android-24 \
  -DCMAKE_BUILD_TYPE=Release .
cmake --build "build/android-$ABI" --target whisper_shim -j"$(nproc)"

DEST="../app/android/app/src/main/jniLibs/$ABI"
mkdir -p "$DEST"
cp "build/android-$ABI/libwhisper.so" "$DEST/libwhisper.so"
echo "-> $(realpath "$DEST/libwhisper.so")"
