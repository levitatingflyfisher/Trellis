import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ml_runtime/ml_runtime.dart';
import 'package:trellis/services/device_services.dart';

/// 1.5.6: the Translate sheet said "no offline translator for English"
/// on a phone that had en→ru downloaded, because the pairs were gated
/// above the tier the real wiring runs at. Go through the real factory,
/// not a test double with a hand-picked tier.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('trellis-real-tier'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('the real wiring can route translations out of English', () async {
    final services = DeviceServices.real(dir);
    final routes = await services.translation!.routesFrom('en');
    expect(routes, isNotEmpty);
    expect(routes.map((r) => r.target), contains('ru'));
  });

  /// Lays every pinned file down at its exact size, which is what
  /// DiskModelStore.isDownloaded checks. Sparse, so 263 MB costs nothing.
  void fakeDownload(DeviceServices services, ModelSpec spec) {
    for (final f in spec.files) {
      final file = File(services.modelStore.pathOf(spec, f))
        ..createSync(recursive: true);
      final raf = file.openSync(mode: FileMode.write)..truncateSync(f.bytes);
      raf.closeSync();
    }
  }

  // 1.5.8: the voice sat at t2, the app runs at t1, so a downloaded voice
  // was never picked and read-aloud stayed on the system voice.
  test('the real wiring uses a downloaded neural voice', () async {
    final services = DeviceServices.real(dir);
    final voice = services.registry.byId('supertonic-en-m1')!;
    expect(await services.resolveSpeechEngine(lang: 'en'), isNull);
    fakeDownload(services, voice);
    expect(await services.resolveSpeechEngine(lang: 'en'), isNotNull);
    expect(await services.resolveSpeechEngine(), isNotNull);
  });

  test('a region tag still finds the English voice', () async {
    final services = DeviceServices.real(dir);
    fakeDownload(services, services.registry.byId('supertonic-en-m1')!);
    expect(await services.resolveSpeechEngine(lang: 'en-US'), isNotNull);
  });
}
