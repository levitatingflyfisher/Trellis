import 'package:oh_fleet_conformance/oh_fleet_conformance.dart';

// Trellis's entire fleet-standardization posture, in one reviewable place:
// full style tier (OhTheme.light/hearthDark), zero Android permissions
// (the main manifest declares none — enforced, not promised), stock
// analysis options, default sibling design-package path.
void main() => runFleetConformance(const FleetAppConfig(
      appId: 'trellis',
      styleTier: StyleTier.full,
      androidPermissions: {},
    ));
