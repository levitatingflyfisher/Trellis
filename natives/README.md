# natives — the pinned whisper build

`libwhisper.so` = whisper.cpp (pinned below, statically absorbed, CPU-only,
no OpenMP) + `shim/wfs_shim.c`, whose `wfs_*` exports are the ONLY surface
`packages/whisper_ffi` binds. The shim and `whisper_ffi/lib/src/bindings.dart`
are mirrors — change either only with the other.

The shim has two sets of exports:

- **Thirteen over a context that owns its decoder state** (`wfs_init_from_file`,
  `wfs_full`, the getters, `wfs_full_lang`). The baseline every build has.
- **Fourteen `wfs_state_*`** (1.5.3): the model loaded once with no state,
  and a fresh `whisper_state` per window, freed once its results are read.
  This is what a job uses when it keeps the model across windows. A context
  that owns its state seeds decoder 0's sampling RNG only when the state is
  created, and temperature-fallback decoding draws from it. A kept context
  would make each window's text depend on the windows before it, so a
  resumed or retried job would not match an uninterrupted one. The Dart side
  binds this set all-or-nothing and falls back to the first set on an older
  `.so`.

Android carries two builds of the same source (see below); every other
platform has one.

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
  two libraries into `app/android/app/src/main/jniLibs/arm64-v8a/`, where
  gradle packs them:

  | File | Target | Who loads it |
  |---|---|---|
  | `libwhisper.so` | baseline `armv8-a` | every arm64 phone; the safe default |
  | `libwhisper_dotprod.so` | `armv8.2-a+dotprod+fp16` | phones whose every core lists `asimddp` and `asimdhp` in `/proc/cpuinfo` |

  Why two: the baseline can't use ggml's int8 dot-product (`sdot`/`udot`)
  or fp16 arithmetic kernels, and those are most of whisper's speed on a
  modern phone (a 1-hour episode took ~4 h on a Pixel 6a with the baseline
  alone). An older core would die on an illegal instruction, which can't
  be caught, so `whisperLibraryPath()` reads the kernel's feature list
  and never just tries. It falls back to the baseline if the fast build
  won't open or bind. The run's log line says which one ran (`lib dotprod`
  / `lib baseline`).

  The fast build uses ggml's own `GGML_CPU_ARM_ARCH`, not hand-made flags.
  Each variant has its own build dir (cache values would otherwise stick),
  and its own SONAME via `WFS_LIB_NAME`, because bionic dedupes loaded
  libraries by SONAME, so a renamed copy would collide. `JOBS` (default 3)
  keeps the build inside heavy.sh's memory cap.

  **Run this before any release APK build** — without it the APK ships no
  transcription engine. Verify:
  - `unzip -l app-arm64-v8a-release.apk | grep libwhisper` lists both;
  - `llvm-readelf -d <lib> | grep -E 'NEEDED|SONAME'` lists only
    libm/libdl/libc (bionic) and the file's own name;
  - `llvm-objdump -d --no-show-raw-insn --mattr=+dotprod,+fullfp16 <lib> |
    grep -cE '\s[su]dot\s'` is in the hundreds for the dotprod build and 0
    for the baseline.
- **Linux (the native test lane + desktop runs):** `./build-linux.sh` on a
  machine with a C++ toolchain. This workshop box has none — use the
  container instead:

  ```bash
  podman run --rm --memory=4g --memory-swap=5g -v "$PWD:/w:Z" \
    registry.fedoraproject.org/fedora:43 \
    bash -c "dnf install -y gcc gcc-c++ cmake ninja-build && cd /w && \
      cmake -B build/linux -G Ninja -DCMAKE_BUILD_TYPE=Release . && \
      cmake --build build/linux --target whisper_shim -j3 && \
      mkdir -p out/linux && cp build/linux/libwhisper.so out/linux/"
  ```

  The memory flags matter: rootless podman moves the container into its
  own cgroup scope, outside heavy.sh's cap.

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
  Android's fast build names its target explicitly instead
  (`GGML_CPU_ARM_ARCH`), and the app picks it at runtime.
- `WFS_LIB_NAME` — the output name is also the SONAME; each variant needs
  its own.
- CPU-only (`use_gpu=false` in the shim as well): GPU offload would be an
  explicit later decision, never a silent default.
