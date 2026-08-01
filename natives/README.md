# natives — the pinned whisper build

One artifact per platform: `libwhisper.so` = whisper.cpp (pinned below,
statically absorbed, CPU-only, no OpenMP) + `shim/wfs_shim.c`, whose twelve
`wfs_*` exports are the ONLY surface `packages/whisper_ffi` binds. The shim
and `whisper_ffi/lib/src/bindings.dart` are mirrors — change either only
with the other.

## The pin

| What | Value |
|---|---|
| Upstream | https://github.com/ggml-org/whisper.cpp |
| Tag | `v1.8.3` |
| Commit | `2eeeba56e9edd762b4b38467bab96c2517163158` |

Fetch it (the clone is gitignored, only this recipe is committed):

```bash
git clone --depth 1 --branch v1.8.3 \
  https://github.com/ggml-org/whisper.cpp.git natives/third_party/whisper.cpp
```

## Build

Everything reproducible is gitignored (`third_party/`, `build/`, `out/`,
`models/`, the app's `jniLibs/`); a public repo carries recipes, not
unauditable binaries.

- **Android (the shipping APK):** `./build-android.sh` — cross-compiles
  arm64-v8a with the workshop NDK (override with `ANDROID_NDK`) and drops
  the result into `app/android/app/src/main/jniLibs/arm64-v8a/`, where
  gradle packs it and the loader resolves the bare soname
  `DeviceServices.whisperLibraryPath()` returns. **Run this before any
  release APK build** — without it the APK ships no transcription engine.
  Verify: `unzip -l app-arm64-v8a-release.apk | grep libwhisper` and
  `llvm-readelf -d libwhisper.so | grep NEEDED` must list only
  libm/libdl/libc (bionic).
- **Linux (the native test lane + desktop runs):** `./build-linux.sh` on a
  machine with a C++ toolchain. This workshop box has none — use the
  container instead:

  ```bash
  podman run --rm -v "$PWD:/w:Z" registry.fedoraproject.org/fedora:43 \
    bash -c "dnf install -y gcc gcc-c++ cmake ninja-build && cd /w && \
      cmake -B build/linux -G Ninja -DCMAKE_BUILD_TYPE=Release . && \
      cmake --build build/linux --target whisper_shim && \
      mkdir -p out/linux && cp build/linux/libwhisper.so out/linux/"
  ```

## The pinned test model

The native lane (`dart test --tags native --run-skipped` in
`packages/whisper_ffi`) loads `models/ggml-tiny-q8_0.bin` — the same file
the app's registry pins:

```bash
curl -sL -o models/ggml-tiny-q8_0.bin \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny-q8_0.bin"
sha256sum models/ggml-tiny-q8_0.bin
# c2085835d3f50733e2ff6e4b41ae8a2b8d8110461e18821b09a15c40c42d1cca  (43537433 bytes)
```

A hash mismatch means do not use the file — the registry's trust law
applies to test fixtures too.

## Build laws encoded in CMakeLists.txt

- `BUILD_SHARED_LIBS OFF` as CACHE FORCE — a plain `set()` loses to
  upstream's `option()`, and a shared ggml leaves the shim with dangling
  `DT_NEEDED` entries on device (observed, not theoretical).
- `GGML_OPENMP OFF` — Android ships no `libomp.so`; ggml's own thread
  pool honors `n_threads` through `whisper_full_params`.
- `GGML_NATIVE OFF` — no `-march=native`; a family's hardware varies.
- CPU-only (`use_gpu=false` in the shim as well): GPU offload would be an
  explicit later decision, never a silent default.
