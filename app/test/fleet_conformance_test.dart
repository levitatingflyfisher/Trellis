import 'package:oh_fleet_conformance/oh_fleet_conformance.dart';

/// Trellis's recorded fleet posture — every deliberate divergence from
/// fleet canon lives in this one config, enforced as tests (the fleet's
/// prime directive: a value is worth exactly the test that fails when it
/// stops being true).
void main() => runFleetConformance(const FleetAppConfig(
      appId: 'trellis',
      // C7 is ON: the app bundles the fleet's Lora/Nunito for the wall
      // aesthetic (proposal-2 §12), so every glyph the UI prints must
      // exist in our own cmaps — the ≤/≥ tofu that boxed in Peckish is
      // exactly what this check exists to catch.
      //
      // C2 (sanctuary_backup_ui) is a RECORDED DIVERGENCE, not a gap:
      // backup here is packages/backup_core on the REAL
      // sanctuary_auth_core (per-app HKDF domain + AAD) — the .ohbk
      // envelope carries this app's 11-table spine plus both-donor
      // migration, which the shared UI package's envelope does not model.
      // And there is no vault to prune: backups go to a user-chosen file
      // through the picker, never an app-managed snapshot dir, so
      // runStartupMaintenance has nothing to maintain. The crypto law C2
      // exists to protect is kept; the package it names is not used.
      //
      // C3's budgets.json carries the first honest numbers: measured from
      // the v1.0 release artifacts (2026-08-12), then +5% — the ratchet
      // compares only when build/ artifacts exist, so a plain test run
      // stays green and a bloated release build fails loudly.
      //
      // C8 is ON: the app's two play/pause toggles migrated onto
      // `OhIconButton.filled` from openhearth_design (the fix for
      // Campaign 9 Phase 0's "blank circles"), so a bare `IconButton.filled`
      // or `IconButton.filledTonal` reappearing in lib/ is now a red suite,
      // not a silent invisible button.
      checks: {
        FleetCheck.c1Style,
        FleetCheck.c3Budgets,
        FleetCheck.c4Permissions,
        FleetCheck.c6Harness,
        FleetCheck.c7Fonts,
        FleetCheck.c8IconButtons,
      },
      // Tier T: canonical openhearth_design tokens consumed by sibling
      // path; theme construction stays local (local ThemeData over
      // package tokens).
      styleTier: StyleTier.tokens,
      // The app root is PrimingTrellis/app — one level deeper than the
      // fleet norm of <AppName>/ being the Flutter root — so the default
      // ../ohStyle path would miss the canonical package and C1 would
      // fail for the wrong reason. This override reaches the SAME
      // canonical sibling, not a fork.
      designPackagePath: '../../ohStyle/openhearth_design',
      // The exact source-manifest permission surface, both directions —
      // ADR-0003 law 7 verbatim: INTERNET (podcasts and model downloads),
      // FOREGROUND_SERVICE + its dataSync (transcription jobs) and
      // mediaPlayback (the player) subtypes, POST_NOTIFICATIONS (the job
      // card's notification), WAKE_LOCK (jobs and playback outliving the
      // screen), and nothing else.
      androidPermissions: {
        'android.permission.INTERNET',
        'android.permission.FOREGROUND_SERVICE',
        'android.permission.FOREGROUND_SERVICE_DATA_SYNC',
        'android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK',
        'android.permission.POST_NOTIFICATIONS',
        'android.permission.WAKE_LOCK',
      },
      // C4 v2 — the release MERGED surface, measured from the first real
      // release build: the six declared above, plus two the merge
      // process adds. ACCESS_NETWORK_STATE rides in with the player and
      // foreground-task plugins and is functional (the metered-download
      // guard needs it); RECEIVE_BOOT_COMPLETED (foreground_task's
      // restart-at-boot, unused here) is tools:node-removed in the
      // source manifest, so its absence below is enforced too.
      mergedAndroidPermissions: {
        'android.permission.INTERNET',
        'android.permission.FOREGROUND_SERVICE',
        'android.permission.FOREGROUND_SERVICE_DATA_SYNC',
        'android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK',
        'android.permission.POST_NOTIFICATIONS',
        'android.permission.WAKE_LOCK',
        'android.permission.ACCESS_NETWORK_STATE',
        'com.openhearth.trellis.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION',
      },
    ));
