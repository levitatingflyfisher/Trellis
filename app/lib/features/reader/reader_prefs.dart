/// Per-profile reader preferences (Campaign 4 Phase 1): typography for the
/// scroll/print reader — RSVP and the ticker keep their own tuned displays
/// and are untouched. One JSON blob in [Profiles.readerPrefsJson] rather
/// than one column per field, the same shape the study crown's
/// `Cards.stateJson` already uses (see `encodeCardState` in database.dart)
/// — later phases extend the JSON here without a further schema hop.
library;

import 'dart:convert';

/// The two faces the app ships: Lora and Nunito, bundled as package fonts
/// by openhearth_design. (The app's one font of its own is the mono subset
/// for code and table blocks on the web — see reader_code_face.dart.)
enum ReaderTypeface { lora, nunito }

ReaderTypeface _typefaceFromWire(Object? v) => switch (v) {
      'nunito' => ReaderTypeface.nunito,
      _ => ReaderTypeface.lora,
    };

String _typefaceToWire(ReaderTypeface t) => switch (t) {
      ReaderTypeface.lora => 'lora',
      ReaderTypeface.nunito => 'nunito',
    };

/// The package that bundles the reader's two faces. Pass it with
/// [readerTypefaceFontFamily] in every `copyWith(fontFamily:, package:)`:
/// a bare `'Lora'` would silently fall back to the platform font now that
/// the app carries no Lora or Nunito files of its own, and a pre-prefixed name would
/// be prefixed twice by a theme style that already carries the package.
const String kReaderFontPackage = 'openhearth_design';

/// The family name for [t], always one of the two faces openhearth_design
/// bundles (C7 pins glyph coverage for exactly these), never a system face.
/// Unprefixed: pair it with `package: kReaderFontPackage`.
String readerTypefaceFontFamily(ReaderTypeface t) => switch (t) {
      ReaderTypeface.lora => 'Lora',
      ReaderTypeface.nunito => 'Nunito',
    };

double _num(Object? v, double fallback) => v is num ? v.toDouble() : fallback;

/// Typography for the print reader (scroll mode). Defaults match the
/// reader's pre-Campaign-4 hardcoded values exactly, so an unset/corrupt
/// blob renders identically to before this pass.
class ReaderTypography {
  const ReaderTypography({
    this.fontScale = 1.0,
    this.lineHeight = 1.6,
    this.maxTextWidth = 680,
    this.paragraphSpacing = 8,
    this.typeface = ReaderTypeface.lora,
    this.justified = false,
  });

  /// Multiplies the print body's base font size (theme bodyLarge).
  final double fontScale;

  /// The print body's line height (Flutter `TextStyle.height`).
  final double lineHeight;

  /// The print column's max width, dp (replaces the reader's hardcoded
  /// 680 constraint).
  final double maxTextWidth;

  /// Extra vertical padding between blocks, dp, on top of the reader's
  /// existing 8dp base.
  final double paragraphSpacing;

  final ReaderTypeface typeface;

  /// Ragged-right (false, the default) or justified (true). Flutter
  /// justifies without hyphenation and this reader justifies by
  /// distributing space within each wrapped line — including, honestly,
  /// its last line — so wide gaps can appear on narrow screens; the
  /// settings copy says so (ADR-0010's honest ceiling, not silently
  /// hidden).
  final bool justified;

  ReaderTypography copyWith({
    double? fontScale,
    double? lineHeight,
    double? maxTextWidth,
    double? paragraphSpacing,
    ReaderTypeface? typeface,
    bool? justified,
  }) =>
      ReaderTypography(
        fontScale: fontScale ?? this.fontScale,
        lineHeight: lineHeight ?? this.lineHeight,
        maxTextWidth: maxTextWidth ?? this.maxTextWidth,
        paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
        typeface: typeface ?? this.typeface,
        justified: justified ?? this.justified,
      );

  Map<String, Object?> toJson() => {
        'fontScale': fontScale,
        'lineHeight': lineHeight,
        'maxTextWidth': maxTextWidth,
        'paragraphSpacing': paragraphSpacing,
        'typeface': _typefaceToWire(typeface),
        'justified': justified,
      };

  /// Lenient the way the house codecs are lenient (`decodeFsrsCardState`):
  /// a missing or malformed key falls back to its default rather than
  /// throwing — a corrupt blob degrades to "as if never set", never a
  /// crash on open.
  factory ReaderTypography.fromJson(Map<String, dynamic>? m) {
    if (m == null) return const ReaderTypography();
    const d = ReaderTypography();
    return ReaderTypography(
      fontScale: _num(m['fontScale'], d.fontScale),
      lineHeight: _num(m['lineHeight'], d.lineHeight),
      maxTextWidth: _num(m['maxTextWidth'], d.maxTextWidth),
      paragraphSpacing: _num(m['paragraphSpacing'], d.paragraphSpacing),
      typeface: _typefaceFromWire(m['typeface']),
      justified: m['justified'] is bool ? m['justified'] as bool : d.justified,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ReaderTypography &&
      other.fontScale == fontScale &&
      other.lineHeight == lineHeight &&
      other.maxTextWidth == maxTextWidth &&
      other.paragraphSpacing == paragraphSpacing &&
      other.typeface == typeface &&
      other.justified == justified;

  @override
  int get hashCode => Object.hash(
      fontScale, lineHeight, maxTextWidth, paragraphSpacing, typeface, justified);
}

/// How this reader last read: the mode, the Words speed, and the nearby-
/// words display with its focus spread. Remembered per reader, so someone
/// who chose Scroll, or Words at 450, gets that back on the next open
/// (audit about-face-01: these were session-scoped and lost on every
/// open). The mode travels as a wire name ('words' | 'scroll' | 'lines');
/// the screen maps it to its own enum.
class ReaderSession {
  const ReaderSession({
    this.mode = 'words',
    this.wpm = 300,
    this.nearbyWords = false,
    this.focusSpread = 2.0,
  });

  final String mode;
  final double wpm;
  final bool nearbyWords;
  final double focusSpread;

  ReaderSession copyWith(
          {String? mode,
          double? wpm,
          bool? nearbyWords,
          double? focusSpread}) =>
      ReaderSession(
        mode: mode ?? this.mode,
        wpm: wpm ?? this.wpm,
        nearbyWords: nearbyWords ?? this.nearbyWords,
        focusSpread: focusSpread ?? this.focusSpread,
      );

  Map<String, Object?> toJson() => {
        'mode': mode,
        'wpm': wpm,
        'nearbyWords': nearbyWords,
        'focusSpread': focusSpread,
      };

  factory ReaderSession.fromJson(Map<String, dynamic>? m) {
    if (m == null) return const ReaderSession();
    const d = ReaderSession();
    final mode = m['mode'];
    return ReaderSession(
      mode: mode is String && const {'words', 'scroll', 'lines'}.contains(mode)
          ? mode
          : d.mode,
      wpm: _num(m['wpm'], d.wpm).clamp(100, 1500).toDouble(),
      nearbyWords:
          m['nearbyWords'] is bool ? m['nearbyWords'] as bool : d.nearbyWords,
      focusSpread: _num(m['focusSpread'], d.focusSpread).clamp(0.8, 4.0).toDouble(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ReaderSession &&
      other.mode == mode &&
      other.wpm == wpm &&
      other.nearbyWords == nearbyWords &&
      other.focusSpread == focusSpread;

  @override
  int get hashCode => Object.hash(mode, wpm, nearbyWords, focusSpread);
}

/// The whole [Profiles.readerPrefsJson] blob, decoded. Started as typography
/// only (Phase 5's lifetime totals read [ReadingDays], not this blob); the
/// reading mode, speed and nearby-words display joined it as [session] once
/// the audit found them lost on every open (about-face-01). Its
/// own doc always called the shape
/// open to "a sibling key landing here later without a further schema hop."
/// [lastPlayedWorkId] (Campaign 9 Phase 2, "resume after restart") is that
/// sibling key: this app has no SharedPreferences usage anywhere (see
/// [SavedViews]'s own doc) and no new table/column is warranted for one
/// nullable int, so it rides the SAME per-profile JSON blob the reader
/// already owns. This is now genuinely a shared app-prefs blob, not a
/// reader-only one, even though the class name and column predate that.
class ReaderPrefs {
  const ReaderPrefs(
      {this.typography = const ReaderTypography(),
      this.session = const ReaderSession(),
      this.lastPlayedWorkId});

  final ReaderTypography typography;

  /// How this reader last read (mode, speed, nearby words).
  final ReaderSession session;

  /// The most recently played work's id, for the mini bar to rehydrate a
  /// paused thread back to it after an app restart — null means nothing
  /// has ever played, or the player has never recorded one yet.
  final int? lastPlayedWorkId;

  /// [clearLastPlayedWorkId] is a separate flag (not "pass null") because
  /// null already means "leave the field as is" for every other optional
  /// param here — the same shape [FeedsDao.updateRefreshState]'s own
  /// update-flag pair uses for exactly this reason.
  ReaderPrefs copyWith({
    ReaderTypography? typography,
    ReaderSession? session,
    int? lastPlayedWorkId,
    bool clearLastPlayedWorkId = false,
  }) =>
      ReaderPrefs(
        typography: typography ?? this.typography,
        session: session ?? this.session,
        lastPlayedWorkId: clearLastPlayedWorkId
            ? null
            : (lastPlayedWorkId ?? this.lastPlayedWorkId),
      );

  String encode() => json.encode({
        'typography': typography.toJson(),
        'session': session.toJson(),
        if (lastPlayedWorkId != null) 'lastPlayedWorkId': lastPlayedWorkId,
      });

  /// Never throws: an empty column (a brand-new profile), a non-JSON
  /// string, or a JSON value that isn't an object all decode to the
  /// all-default prefs.
  static ReaderPrefs decode(String raw) {
    if (raw.trim().isEmpty) return const ReaderPrefs();
    try {
      final decoded = json.decode(raw);
      if (decoded is! Map<String, dynamic>) return const ReaderPrefs();
      final rawId = decoded['lastPlayedWorkId'];
      return ReaderPrefs(
          typography: ReaderTypography.fromJson(
              decoded['typography'] as Map<String, dynamic>?),
          session: ReaderSession.fromJson(
              decoded['session'] is Map<String, dynamic>
                  ? decoded['session'] as Map<String, dynamic>
                  : null),
          lastPlayedWorkId: rawId is int ? rawId : null);
    } on FormatException {
      return const ReaderPrefs();
    }
  }
}
