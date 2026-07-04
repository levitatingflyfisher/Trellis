# How-to: export a course to Anki

Task-oriented: turn a Trellis course into an Anki `.apkg` deck you can study in Anki.

## Availability

Anki export is **native-only** — it builds a real Anki package (a SQLite collection
zipped into an `.apkg`), which needs `dart:io` + `sqlite3`. On the **web build the
export button is hidden** (the code resolves to a throwing stub via a conditional
import). Use the Android/desktop app to export.

## Steps

1. Open a course (tap it in the Library to reach its **Course map**).
2. In the app bar, tap **Export to Anki (.apkg)** (the download icon — shown only on
   supported native targets).
3. The app builds the `.apkg` locally, then hands it to the OS **share sheet**. Send
   it wherever you like (save to files, share to another device) and open it in Anki.

## What you get

- One Anki note/card per Trellis retrieval item, packaged as a standard `.apkg`.
- The export is produced entirely on-device; nothing is uploaded by the app — the
  share sheet is where *you* decide the destination (see [privacy-model.md](../privacy-model.md)).

## If it fails

The app shows an "Anki export failed" message with the error. Common causes are
storage/permission issues writing the temporary file. Retry; if it persists, capture
the message and check `lib/features/curriculum/data/anki/anki_export_io.dart`.

## Why interop instead of lock-in

Exporting to Anki lets Trellis feed the largest existing spaced-repetition ecosystem
rather than trapping your cards. It's a deliberate native affordance — one of the
reasons the native app exists alongside the ohPrimer PWA (see the
[white paper](../whitepaper.md)).
