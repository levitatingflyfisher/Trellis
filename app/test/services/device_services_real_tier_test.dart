import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
}
