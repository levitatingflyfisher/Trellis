/// The real device accelerometer, mapped onto [AccelerationSample] — the
/// only file in this feature that imports sensors_plus. Every other file
/// that cares about shakes (ShakeDetector, PlayerController) reads the
/// small pure type instead, so nothing else here ever has to know a
/// platform channel is involved.
library;

import 'package:sensors_plus/sensors_plus.dart';

import 'shake_detector.dart';

Stream<AccelerationSample> realAccelerometerSamples() =>
    accelerometerEventStream()
        .map((e) => AccelerationSample(e.x, e.y, e.z));
