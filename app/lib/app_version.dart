/// The app's version, kept equal to pubspec.yaml's `version:` by
/// test/app_version_test.dart. A const rather than package_info_plus: the
/// only reader is the User-Agent, which must exist before any platform
/// channel answers.
library;

const appVersion = '1.5.5';

/// Sent on every native fetch (ADR-0017). Feed hosts read the User-Agent
/// to tell podcast apps apart and to reach a misbehaving one; Dart's
/// default ("Dart/3.x (dart:io)") looks like a scraper and some hosts
/// refuse it.
const trellisUserAgent =
    'Trellis/$appVersion (+https://github.com/levitatingflyfisher)';
