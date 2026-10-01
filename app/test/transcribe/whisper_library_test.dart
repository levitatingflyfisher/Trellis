import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/features/transcribe/whisper_library.dart';

/// Which whisper build a phone loads: the dotprod+fp16 one only when the
/// CPU says it has both, the baseline otherwise or when the fast one won't
/// open. An illegal instruction can't be caught, so the gate is the
/// kernel's feature list, never a try.
void main() {
  // A Pixel 6a (Tensor G1): ARMv8.2 with dotprod and fp16.
  const tensorG1 = '''
processor\t: 0
BogoMIPS\t: 49.15
Features\t: fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid asimdrdm lrcpc dcpop asimddp
CPU implementer\t: 0x41

processor\t: 7
BogoMIPS\t: 49.15
Features\t: fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid asimdrdm lrcpc dcpop asimddp
CPU implementer\t: 0x41
''';
  // A Cortex-A53 phone: baseline ARMv8.0, neither feature.
  const a53 = '''
processor\t: 0
Features\t: fp asimd evtstrm aes pmull sha1 sha2 crc32 cpuid
''';

  group('cpuHasDotprodFp16', () {
    test('true when every core lists asimddp and asimdhp', () {
      expect(cpuHasDotprodFp16(tensorG1), isTrue);
    });

    test('false on a baseline core', () {
      expect(cpuHasDotprodFp16(a53), isFalse);
    });

    test('dotprod without fp16 is not enough', () {
      expect(cpuHasDotprodFp16('Features\t: fp asimd asimddp\n'), isFalse);
    });

    test('a core without LSE atomics gets the baseline', () {
      // -march=armv8.2-a lets the compiler emit LSE atomics.
      expect(
        cpuHasDotprodFp16('Features\t: fp asimd fphp asimdhp asimddp\n'),
        isFalse,
      );
    });

    test('a core without scalar fp16 gets the baseline', () {
      expect(
        cpuHasDotprodFp16('Features\t: fp asimd atomics asimdhp asimddp\n'),
        isFalse,
      );
    });

    test('fp16 without dotprod is not enough', () {
      expect(cpuHasDotprodFp16('Features\t: fp asimd fphp asimdhp\n'), isFalse);
    });

    test('a core missing the features rules the build out', () {
      expect(
        cpuHasDotprodFp16(
          'Features\t: fp asimd asimdhp asimddp\n'
          'Features\t: fp asimd\n',
        ),
        isFalse,
      );
    });

    test('matches whole tokens, not substrings', () {
      expect(cpuHasDotprodFp16('Features\t: xasimddp asimdhpx\n'), isFalse);
    });

    test('no Features line means no claim', () {
      expect(cpuHasDotprodFp16(''), isFalse);
      expect(cpuHasDotprodFp16('processor\t: 0\n'), isFalse);
    });
  });

  group('chooseWhisperLibrary', () {
    test('dotprod on an arm64 phone that has the features, no note', () {
      final opened = <String>[];
      final c = chooseWhisperLibrary(
        androidArm64: true,
        readCpuinfo: () => tensorG1,
        open: opened.add,
      );
      expect(c.path, dotprodWhisperLibrary);
      expect(c.reason, isNull);
      expect(opened, [dotprodWhisperLibrary]);
    });

    test('baseline "no dotprod" without them, never opening dotprod', () {
      final opened = <String>[];
      final c = chooseWhisperLibrary(
        androidArm64: true,
        readCpuinfo: () => a53,
        open: opened.add,
      );
      expect(c.path, baselineWhisperLibrary);
      expect(c.reason, 'no dotprod');
      expect(opened, isEmpty);
    });

    test('baseline names why the dotprod library would not open', () {
      final c = chooseWhisperLibrary(
        androidArm64: true,
        readCpuinfo: () => tensorG1,
        open: (p) => throw ArgumentError('dlopen failed: $p'),
      );
      expect(c.path, baselineWhisperLibrary);
      expect(c.reason, startsWith('dotprod open failed: '));
      expect(c.reason, contains('dlopen failed'));
    });

    test('a long open failure is cut short for the log line', () {
      final c = chooseWhisperLibrary(
        androidArm64: true,
        readCpuinfo: () => tensorG1,
        open: (_) => throw StateError('x' * 500),
      );
      expect(c.reason!.length, lessThan(100));
    });

    test('baseline "cpuinfo unreadable" when /proc/cpuinfo cannot be read',
        () {
      final c = chooseWhisperLibrary(
        androidArm64: true,
        readCpuinfo: () => throw const FormatException('denied'),
        open: (_) => fail('opened without knowing the CPU'),
      );
      expect(c.path, baselineWhisperLibrary);
      expect(c.reason, 'cpuinfo unreadable');
    });

    test('anything but Android arm64 never reads the CPU', () {
      final c = chooseWhisperLibrary(
        androidArm64: false,
        readCpuinfo: () => fail('read cpuinfo off arm64'),
        open: (_) => fail('opened off arm64'),
      );
      expect(c.path, baselineWhisperLibrary);
      expect(c.reason, isNull);
    });
  });

  test('WhisperLibraryPicker probes once and caches the answer', () {
    var reads = 0;
    var opens = 0;
    final picker = WhisperLibraryPicker(
      androidArm64: true,
      readCpuinfo: () {
        reads++;
        return tensorG1;
      },
      open: (_) => opens++,
    );
    expect(picker.path, dotprodWhisperLibrary);
    expect(picker.path, dotprodWhisperLibrary);
    expect(reads, 1);
    expect(opens, 1);
  });

  test('whisperLibraryKind names the build for the log line', () {
    expect(whisperLibraryKind('libwhisper_dotprod.so'), 'dotprod');
    expect(
      whisperLibraryKind('/x/natives/out/linux/libwhisper.so'),
      'baseline',
    );
    expect(whisperLibraryKind('libwhisper.so'), 'baseline');
    expect(whisperLibraryKind('libwhisper.so', 'no dotprod'),
        'baseline (no dotprod)');
    expect(whisperLibraryKind('libwhisper_dotprod.so', null), 'dotprod');
  });
}
