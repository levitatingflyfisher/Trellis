import 'package:oh_fleet_conformance/oh_fleet_conformance.dart';

// Trellis's entire fleet-standardization posture, in one reviewable place:
// full style tier (OhTheme.light/hearthDark), zero Android permissions
// (the main manifest declares none — enforced, not promised), stock
// analysis options, default sibling design-package path.
void main() => runFleetConformance(const FleetAppConfig(
      appId: 'trellis',
      styleTier: StyleTier.full,
      androidPermissions: {},
      // C4 v2 — the release MERGED surface: source permissions plus
      // what plugins and the manifest merge inject. Bites when an APK
      // build has left a merged manifest under build/ (dev box).
      mergedAndroidPermissions: {
        'com.openhearth.trellis.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION',
      },
    ));
