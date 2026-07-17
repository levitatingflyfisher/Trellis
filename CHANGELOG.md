# Changelog

All notable changes to Trellis will be documented in this file.

## [Unreleased]

### Added
- Continuous integration — Trellis's first CI ever. A GitHub Actions
  workflow (push + PR) clones the sibling path-dep packages, pins the
  fleet's Flutter 3.38.7, and runs `flutter analyze` + the full test
  suite. Until now nothing verified that Trellis even built.
- Size budgets recorded in `budgets.json` (gzipped web `main.dart.js`
  and arm64 release APK, measured +5%), ratcheted by the fleet
  conformance suite so growth is a deliberate decision.
- Snapshot vault ("Previous backups" on the Backup & Restore screen):
  every encrypted export and every restore leaves a stamped on-device
  snapshot (keep-10, pinnable) you can restore, pin or delete.
- Mandatory pre-restore snapshot: a restore refuses to run unless the
  current data was snapshotted (and the snapshot verified by read-back)
  first — restoring is now reversible. This matters doubly in Trellis:
  courses and study progress live in SharedPreferences, which has no
  cross-key transaction, so a restore interrupted mid-write is not
  crash-atomic — the verified snapshot is precisely its safety net.
- Preview before restore: the confirm dialog shows the backup's age and
  contents next to what's on the device now, validated by the same gate
  the restore itself uses.
- Encrypted exports verify themselves by read-back before reporting
  success, and the `.ohbk` envelope now carries a `createdAt` stamp
  (older backups still restore and preview as "unknown age"; older app
  versions still read new backups — every legacy key is kept).
- Silent freshness snapshot on app open when the newest one is older
  than 7 days and a backup key exists.

### Changed
- Graduated to the shared `openhearth_design` system: the theme is now
  the canonical `OhTheme.light` / `OhTheme.hearthDark` (hearth is
  Trellis's brand — no accent override) instead of a hand-rolled
  `ColorScheme.fromSeed` on the same hearth literal. Surfaces move to
  the warm linen / brown-black ramps, buttons become stadium-shaped,
  and the app now bundles and uses the fleet's Lora (headings) and
  Nunito (UI/body) fonts — offline, zero font fetches.
- Restored heading hierarchy under the new type ladder (course-card
  titles, the library empty state and the course-map "Concepts" heading
  now use `titleLarge`) and kept the RSVP play/pause glyph visible on
  its filled button.
- Backup envelope emission/validation now goes through the shared
  `sanctuary_backup_ui` 0.2.0 `BackupEnvelope` helper instead of a
  hand-rolled copy of the same shape.
