#!/usr/bin/env bash
# Fails unless a release APK carries both whisper libraries.
#
# They live in the gitignored app/android/app/src/main/jniLibs/arm64-v8a/, and
# a release built from a clean `git archive` does not get them. Gradle packs
# whatever it finds without complaint, which is how 1.5.9 shipped with no
# transcription engine. The release recipe runs this on every arm64 APK.
#
# Since 1.6.0 it must also carry PDFium (PDF intake), and exactly the pinned
# build. The pdfium_flutter plugin downloads libpdfium.so from GitHub
# (bblanchon/pdfium-binaries) while the app builds and checks nothing, so
# this is where a swapped or changed binary is caught. The pin is the sha256
# in pdfium-arm64.sha256 beside this script; natives/README.md says how it
# was verified and how to move it.
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

pdfium=lib/arm64-v8a/libpdfium.so
pin_file=$(dirname "$0")/pdfium-arm64.sha256
if ! pin=$(tr -d ' \n\r' <"$pin_file" 2>/dev/null) || [ -z "$pin" ]; then
  echo "check-release-apk: no pin to check PDFium against: $pin_file is missing or empty" >&2
  exit 1
fi
if ! grep -qxF "$pdfium" <<<"$listing"; then
  echo "check-release-apk: $apk is missing $pdfium" >&2
  exit 1
fi
got=$(unzip -p "$apk" "$pdfium" | sha256sum | cut -d' ' -f1)
if [ "$got" != "$pin" ]; then
  echo "check-release-apk: $pdfium is not the pinned PDFium build" >&2
  echo "  pinned: $pin" >&2
  echo "  in APK: $got" >&2
  exit 1
fi

if [ "$status" -ne 0 ]; then
  echo "check-release-apk: put the libraries in app/android/app/src/main/jniLibs/arm64-v8a/ of the build tree (see natives/README.md); git archive does not carry them." >&2
fi
exit "$status"
