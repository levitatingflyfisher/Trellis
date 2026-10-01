#!/usr/bin/env bash
# Builds the two arm64 shims and places them in the app's jniLibs, where
# gradle packs them into the APK and Android's loader resolves the bare
# sonames DeviceServices.whisperLibraryPath() chooses between:
#
#   libwhisper.so          baseline armv8-a, runs on every arm64 phone
#   libwhisper_dotprod.so  armv8.2-a+dotprod+fp16: ggml's int8 sdot/udot
#                          and fp16 kernels, picked at runtime only when
#                          /proc/cpuinfo lists both asimddp and asimdhp
#
# One invocation builds both, so a release can't ship without the fast one.
# Each variant keeps its own build dir: GGML_CPU_ARM_ARCH and WFS_LIB_NAME
# are CMake cache values and would stick if a dir were reused.
#
# ANDROID_NDK defaults to the workshop's checked-in NDK; android-24 matches
# the app's minSdk floor for 16KB-page-safe builds. JOBS stays low because
# heavy.sh's 4 GiB cap kills a wide ggml/whisper C++ build.
set -euo pipefail
cd "$(dirname "$0")"

NDK="${ANDROID_NDK:-/mnt/tera/working/programming/androidDevTools/ndk/28.2.13676358}"
ABI=arm64-v8a
JOBS="${JOBS:-3}"

# The workshop has no system cmake; the Android SDK's serves both builds.
PATH="/mnt/tera/working/programming/androidDevTools/cmake/3.22.1/bin:$PATH"

DEST="../app/android/app/src/main/jniLibs/$ABI"
mkdir -p "$DEST"

# build_variant <lib name> <build dir> [extra cmake args...]
build_variant() {
  local name="$1" dir="$2"
  shift 2
  cmake -B "$dir" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_PLATFORM=android-24 \
    -DCMAKE_BUILD_TYPE=Release \
    -DWFS_LIB_NAME="$name" "$@" .
  cmake --build "$dir" --target whisper_shim -j"$JOBS"
  cp "$dir/lib$name.so" "$DEST/lib$name.so"
  echo "-> $(realpath "$DEST/lib$name.so")"
}

# GGML_CPU_ARM_ARCH is ggml's own knob for -march on ARM; it only applies
# with GGML_NATIVE off, which CMakeLists.txt forces. The baseline sets it
# empty so a stale cache can never leak the fast flags into it.
build_variant whisper "build/android-$ABI" -DGGML_CPU_ARM_ARCH=
build_variant whisper_dotprod "build/android-$ABI-dotprod" \
  -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16
