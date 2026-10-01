import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/painting.dart';
import 'package:openhearth_design/openhearth_design.dart';

/// The app's own bundled family: a Noto Sans Mono subset (pubspec.yaml,
/// assets/fonts/OFL.txt).
const String kReaderMonoFamily = 'NotoSansMono';

/// The face for the reader's code and table blocks.
///
/// Natively this is the ladder's code face, the platform monospace. On the
/// web there is no platform monospace (the build is self-hosted and fetches
/// no fallback fonts), and the ladder's web code face is Nunito, which is
/// proportional, so ASCII tables and indented code from an EPUB lost their
/// columns. There it is the bundled mono subset, with Nunito behind it for
/// any glyph the subset lacks: that row may shift, but nothing draws as a
/// box and nothing is fetched.
///
/// Size, weight and line height match the ladder's code face.
///
/// `inherit: false` on the web branch, because the theme's text styles
/// carry `package: openhearth_design`, and when [Text] merges an
/// inheriting style into that ambient one it hands over the package:
/// 'NotoSansMono' became 'packages/openhearth_design/NotoSansMono', a
/// family no font answers to, and the web drew blank 1-em cells. For the
/// same reason this is a fresh style, not a `copyWith` of the ladder's web
/// face, which itself carries the package. The native branch is the ladder
/// face as it is: since openhearth_design 0.9.2 `code()` is itself
/// `inherit: false`, for the same trap with 'monospace'.
TextStyle readerCodeStyle({Color? color, bool web = kIsWeb}) {
  final ladder = OhTypography.code(color: color, web: web);
  if (!web) return ladder;
  return TextStyle(
    inherit: false,
    fontFamily: kReaderMonoFamily,
    fontFamilyFallback: const ['packages/openhearth_design/Nunito'],
    fontSize: ladder.fontSize,
    fontWeight: ladder.fontWeight,
    height: ladder.height,
    color: color,
  );
}
