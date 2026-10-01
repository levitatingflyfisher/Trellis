/// Which whisper build a device loads. The APK carries two arm64 shims
/// (natives/build-android.sh): a baseline armv8-a one that runs anywhere,
/// and an armv8.2-a+dotprod+fp16 one whose int8 dot-product and fp16
/// kernels make ggml several times faster on phones that have them.
///
/// An illegal instruction kills the process and can't be caught, so the
/// fast build is gated on what the kernel reports, never on trying it.
/// Pure: the caller injects the cpuinfo reader and the opener.
library;

const baselineWhisperLibrary = 'libwhisper.so';
const dotprodWhisperLibrary = 'libwhisper_dotprod.so';

/// Whether every core in [cpuinfo] lists `asimddp` (sdot/udot), `asimdhp`
/// (fp16 vector arithmetic), `fphp` (scalar fp16) and `atomics` (LSE).
/// The last two ride along because `-march=armv8.2-a` lets the compiler
/// use them anywhere. A big.LITTLE phone whose cores disagree would
/// migrate the thread onto one that faults, so every line must say yes,
/// and no Features line at all is no claim.
bool cpuHasDotprodFp16(String cpuinfo) {
  const needed = ['asimddp', 'asimdhp', 'fphp', 'atomics'];
  var lines = 0;
  for (final line in cpuinfo.split('\n')) {
    final colon = line.indexOf(':');
    if (colon < 0 || line.substring(0, colon).trim() != 'Features') continue;
    lines++;
    final features = line.substring(colon + 1).trim().split(RegExp(r'\s+'));
    if (!needed.every(features.contains)) return false;
  }
  return lines > 0;
}

/// The library to load, and why it is the baseline when a phone that could
/// have had dotprod didn't ([reason] is null for the dotprod build and off
/// Android arm64, where there was never a choice).
typedef WhisperLibraryChoice = ({String path, String? reason});

/// The dotprod build on an Android arm64 device that has the features and
/// can open it, the baseline otherwise.
WhisperLibraryChoice chooseWhisperLibrary({
  required bool androidArm64,
  required String Function() readCpuinfo,
  required void Function(String path) open,
}) {
  const baseline = baselineWhisperLibrary;
  if (!androidArm64) return (path: baseline, reason: null);
  final String cpuinfo;
  try {
    cpuinfo = readCpuinfo();
  } catch (_) {
    return (path: baseline, reason: 'cpuinfo unreadable');
  }
  if (!cpuHasDotprodFp16(cpuinfo)) {
    return (path: baseline, reason: 'no dotprod');
  }
  try {
    // A missing or unloadable fast build (a stripped APK, a linker quirk)
    // must cost speed, not transcription.
    open(dotprodWhisperLibrary);
    return (path: dotprodWhisperLibrary, reason: null);
  } catch (e) {
    final msg = e.toString().replaceAll(RegExp(r'\s+'), ' ');
    final short = msg.length > 60 ? '${msg.substring(0, 60)}...' : msg;
    return (path: baseline, reason: 'dotprod open failed: $short');
  }
}

/// [chooseWhisperLibrary] once per isolate: the answer can't change while
/// the process lives, and a job asks for it per run, not per window.
class WhisperLibraryPicker {
  final bool androidArm64;
  final String Function() readCpuinfo;
  final void Function(String path) open;
  WhisperLibraryChoice? _choice;

  WhisperLibraryPicker({
    required this.androidArm64,
    required this.readCpuinfo,
    required this.open,
  });

  WhisperLibraryChoice get choice => _choice ??= chooseWhisperLibrary(
    androidArm64: androidArm64,
    readCpuinfo: readCpuinfo,
    open: open,
  );

  String get path => choice.path;
}

/// `dotprod` or `baseline`, for the run's log line, from the path that was
/// actually opened, with the reason when the baseline is a fallback:
/// `baseline (no dotprod)`.
String whisperLibraryKind(String path, [String? reason]) {
  final kind = path.split('/').last == dotprodWhisperLibrary
      ? 'dotprod'
      : 'baseline';
  return reason == null ? kind : '$kind ($reason)';
}
