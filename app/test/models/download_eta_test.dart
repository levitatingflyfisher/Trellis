import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/models/download_eta.dart';

/// Honest ETA for byte transfers: measured throughput over a recent window,
/// never a made-up number (null until there is evidence), and a stall RAISES
/// the estimate.
void main() {
  test('no estimate before bytes have moved', () {
    final eta = DownloadEta();
    expect(eta.etaMs(remainingBytes: 1000), isNull);
    eta.addSample(atMs: 0, receivedBytes: 0);
    expect(eta.etaMs(remainingBytes: 1000), isNull,
        reason: 'one sample is a position, not a rate');
  });

  test('a steady rate projects linearly', () {
    final eta = DownloadEta();
    // 1000 bytes per second.
    eta.addSample(atMs: 0, receivedBytes: 0);
    eta.addSample(atMs: 1000, receivedBytes: 1000);
    expect(eta.etaMs(remainingBytes: 5000), 5000);
  });

  test('zero remaining is always zero', () {
    final eta = DownloadEta();
    eta.addSample(atMs: 0, receivedBytes: 0);
    eta.addSample(atMs: 1000, receivedBytes: 1000);
    expect(eta.etaMs(remainingBytes: 0), 0);
  });

  test('the estimate follows the recent window, not ancient history', () {
    final eta = DownloadEta(windowMs: 10000);
    // A fast first second, then a long slow stretch: the old speed must
    // fall out of the window.
    eta.addSample(atMs: 0, receivedBytes: 0);
    eta.addSample(atMs: 1000, receivedBytes: 100000);
    for (var t = 2; t <= 30; t++) {
      eta.addSample(atMs: t * 1000, receivedBytes: 100000 + (t - 1) * 100);
    }
    // Recent rate is 100 bytes/s; 1000 bytes remaining ≈ 10s.
    expect(eta.etaMs(remainingBytes: 1000), closeTo(10000, 1500));
  });

  test('no byte growth in the window means no estimate, not infinity', () {
    final eta = DownloadEta(windowMs: 5000);
    eta.addSample(atMs: 0, receivedBytes: 500);
    eta.addSample(atMs: 20000, receivedBytes: 500);
    eta.addSample(atMs: 21000, receivedBytes: 500);
    expect(eta.etaMs(remainingBytes: 1000), isNull);
  });
}
