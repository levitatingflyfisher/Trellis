# Size proposals, 2026-11-08

Savings not taken in 1.5.10, because each needs a choice by the owner or a
change outside this repo. No feature, language, format or setting was removed.

Native libraries are 79.5 MB of the 82.3 MB arm64 APK, so anything else is
small beside them.

## 1. Compress the native libraries

Set `useLegacyPackaging` so the libraries are compressed in the APK.

- Gain: the APK falls to about 37 MB, close to today's 36,440,802 byte
  estimated download.
- Cost: Android unpacks the libraries on install, so the app takes about
  116 MB on the phone instead of about 82 MB, and installs more slowly.
- These are estimates from the APK breakdown. No such build has been made.
- Recommendation: keep today's packaging unless direct APK download size
  matters more than storage on the phone.

## 2. Drop font weights nothing uses

Lora and Nunito are declared by the shared `ohStyle/openhearth_design` package,
in four weights each, 20 to 30 KB compressed per file.

- Gain: at most 20 to 30 KB for each weight that is proven unused.
- Cost: a change to a package other apps share, and each app must be checked.
- Every script the app renders today must keep rendering.
- Recommendation: low priority.

## 3. Remove library licence texts from `META-INF`

Two files, 7,126 bytes compressed.

- Recommendation: do not take this. Licence texts should stay in the app
  unless someone has confirmed they are covered elsewhere.

## 4. Remaining work with unknown gain

- Dead code inside `app/lib`.
- Narrower R8 keep rules than `ai.onnxruntime.**`. A mistake fails only at
  run time, on the code path that loads the models, so each change needs a
  device test of that path.
- Lazy loading of heavy screens or models. Start-up has no measured problem
  to fix at present.
