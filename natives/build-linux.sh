#!/usr/bin/env bash
# Builds natives/out/linux/libwhisper.so — the desktop artifact the
# whisper_ffi native test lane loads (dart test --tags native --run-skipped).
set -euo pipefail
cd "$(dirname "$0")"

# The workshop has no system cmake; the Android SDK's serves both builds.
PATH="/mnt/tera/working/programming/androidDevTools/cmake/3.22.1/bin:$PATH"

cmake -B build/linux -G Ninja -DCMAKE_BUILD_TYPE=Release .
cmake --build build/linux --target whisper_shim -j"$(nproc)"

mkdir -p out/linux
cp build/linux/libwhisper.so out/linux/libwhisper.so
echo "-> $(realpath out/linux/libwhisper.so)"
