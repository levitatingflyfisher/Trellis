import 'package:flutter/material.dart';
import 'package:openhearth_design/openhearth_design.dart';

import '../../db/database.dart';

/// The device's theme choice (fleet ruling: light, dark or follow the
/// phone, default follow the phone, two taps away on every primary screen).
/// It belongs to the device, not to a reader, so it lives in
/// [DeviceSettings]. Trellis never stored a theme before this, so there is
/// no older value to migrate: an unset or unknown value is "follow phone".
class ThemePreferenceController extends ValueNotifier<OhThemeModePreference> {
  ThemePreferenceController(this._db, [super.value = OhThemeModePreference.system]);

  final AppDatabase _db;

  static const storageKey = 'theme_mode';

  static Future<OhThemeModePreference> read(AppDatabase db) async =>
      OhThemeModePreference.fromStorage(
          await db.deviceSettingsDao.read(storageKey));

  /// The stored choice, if it can be read within [deadline]; null on a slow
  /// or failed read. `main()` awaits this before `runApp`, and nothing
  /// before the first frame may hang it (the 1.4.0 lesson): a null here
  /// means the app starts following the phone and applies the stored
  /// choice once it arrives (a brief flash, never a blank screen).
  static Future<OhThemeModePreference?> readBeforeFirstFrame(AppDatabase db,
          {Duration deadline = const Duration(milliseconds: 400)}) =>
      withinDeadline(() => read(db), deadline);

  /// Loads the stored choice (used when the value was not read before
  /// `runApp`, e.g. in widget tests).
  Future<void> load() async => value = await read(_db);

  Future<void> choose(OhThemeModePreference next) async {
    value = next;
    await _db.deviceSettingsDao.write(storageKey, next.storageValue);
  }
}

/// Runs [run] and returns its value, or null if it throws or has not
/// finished within [deadline]. Never throws, never waits past [deadline].
Future<T?> withinDeadline<T>(Future<T> Function() run, Duration deadline) async {
  try {
    return await run().timeout(deadline);
  } catch (_) {
    return null;
  }
}

/// Hands the [ThemePreferenceController] to the screens below it.
class ThemePreferenceScope
    extends InheritedNotifier<ThemePreferenceController> {
  const ThemePreferenceScope(
      {super.key, required ThemePreferenceController controller, required super.child})
      : super(notifier: controller);

  static ThemePreferenceController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ThemePreferenceScope>()
      ?.notifier;
}

const _themeValuePrefix = 'theme:';

/// The theme as a checked group at the foot of a tab's overflow menu: a
/// "Theme" header, then "Follow phone", "Light" and "Dark", the one in use
/// checked. Two taps (⋮, then the choice), every choice named before it
/// is picked. It replaced first an app-bar "Auto" button that said nothing
/// until tapped, then a worded item that opened a chooser: three taps,
/// over the fleet ruling of one or two.
/// [divided] is false where the group is the whole menu.
List<PopupMenuEntry<String>> themeMenuItems(
        ThemePreferenceController controller,
        {bool divided = true}) =>
    [
      if (divided) const PopupMenuDivider(),
      const PopupMenuItem<String>(
        enabled: false,
        height: 32,
        child: Text('Theme'),
      ),
      for (final p in OhThemeModePreference.values)
        CheckedPopupMenuItem<String>(
          key: Key('theme-choice-${p.name}'),
          value: '$_themeValuePrefix${p.name}',
          checked: p == controller.value,
          child: Text(p.label),
        ),
    ];

/// Whether a menu value came from [themeMenuItems]. Each tab checks this
/// before its own default branch, so a theme pick never falls into it.
bool isThemeMenuValue(String value) => value.startsWith(_themeValuePrefix);

/// Applies a pick from [themeMenuItems].
Future<void> chooseThemeFromMenu(
        ThemePreferenceController controller, String value) =>
    controller.choose(OhThemeModePreference.values
        .byName(value.substring(_themeValuePrefix.length)));
