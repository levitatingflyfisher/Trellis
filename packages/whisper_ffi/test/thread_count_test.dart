import 'package:test/test.dart';
import 'package:whisper_ffi/whisper_ffi.dart';

void main() {
  group('whisperThreadsFor', () {
    test('a phone with slow cores uses only its fast ones', () {
      // Pixel 6a (Tensor G1): 4 little + 2 mid + 2 big cores, in kHz.
      const tensor = [
        1803000, 1803000, 1803000, 1803000, //
        2253000, 2253000, 2802000, 2802000,
      ];
      expect(whisperThreadsFor(cores: 8, maxFreqsKhz: tensor), 4);
    });

    test('never more than four, even with many fast cores', () {
      const chip = [1800000, 1800000, 3000000, 3000000, 3000000, 3000000,
        3000000, 3000000];
      expect(whisperThreadsFor(cores: 8, maxFreqsKhz: chip), 4);
    });

    test('a single fast core still gets one thread', () {
      const chip = [1800000, 1800000, 1800000, 2900000];
      expect(whisperThreadsFor(cores: 4, maxFreqsKhz: chip), 1);
    });

    test('uniform or unknown cores leave one for the UI, capped at four',
        () {
      expect(whisperThreadsFor(cores: 4, maxFreqsKhz: const []), 3);
      expect(
          whisperThreadsFor(cores: 4, maxFreqsKhz: const [2, 2, 2, 2]), 3);
      expect(whisperThreadsFor(cores: 16, maxFreqsKhz: const []), 4);
      expect(whisperThreadsFor(cores: 1, maxFreqsKhz: const []), 1);
    });

    test('a partial frequency read is treated as unknown', () {
      expect(
          whisperThreadsFor(cores: 8, maxFreqsKhz: const [1800000, 2800000]),
          4);
    });
  });
}
