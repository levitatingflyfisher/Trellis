#!/usr/bin/env bash
# Fails unless a release APK carries both whisper libraries.
#
# They live in the gitignored app/android/app/src/main/jniLibs/arm64-v8a/, and
# a release built from a clean `git archive` does not get them. Gradle packs
# whatever it finds without complaint, which is how 1.5.9 shipped with no
# transcription engine. The release recipe runs this on every arm64 APK.
#
# Usage: check-release-apk.sh <app-arm64-v8a-release.apk>
set -u

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <apk>" >&2
  exit 2
fi
apk=$1

if ! listing=$(unzip -Z1 "$apk" 2>/dev/null); then
  echo "check-release-apk: cannot read $apk" >&2
  exit 1
fi

status=0
for lib in lib/arm64-v8a/libwhisper.so lib/arm64-v8a/libwhisper_dotprod.so; do
  if ! grep -qxF "$lib" <<<"$listing"; then
    echo "check-release-apk: $apk is missing $lib" >&2
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  echo "check-release-apk: put the libraries in app/android/app/src/main/jniLibs/arm64-v8a/ of the build tree (see natives/README.md); git archive does not carry them." >&2
fi
exit "$status"
