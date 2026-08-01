/// The one place skein's version lives. `/api/health`'s body and the
/// `trellis-skein/<version>` User-Agent both read this constant — never
/// pubspec.yaml at runtime (pure Dart has no reliable way to do that) — and
/// a test regexes pubspec.yaml to keep this from drifting from the
/// package's declared version (conventions.md: "the claim outlived the
/// code").
const String skeinVersion = '0.1.0';
